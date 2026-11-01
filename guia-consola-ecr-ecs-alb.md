# Guía manual en consola: ECR + ECS Fargate + ALB

Módulo 2 del tutorial *Spring Boot de local a producción: CI/CD con GitHub Actions y AWS*.

**Alcance:** los pasos 0 a 10 son el módulo 2. El paso 11 (rol de AWS para GitHub con OIDC) abre el módulo 3, y el paso 12 es su última lección: revisar los gastos y eliminar la infraestructura. Los tiempos son estimados de ejecución en vivo.

**Idioma de la consola:** esta guía usa los nombres de los campos en inglés. Si tu consola está en español, los nombres cambian (por ejemplo *Target type* se ve como *Tipo de destino*). Puedes cambiar el idioma en los ajustes de la consola (engranaje, arriba a la derecha; verifica la ruta exacta) para que coincida con la guía.

> **Aviso:** la consola de AWS cambia etiquetas y pantallas con frecuencia; si algo no coincide con lo que ves, busca el equivalente en tu consola. Verifica los costos con la **AWS Pricing Calculator** antes de crear recursos.

## Nombres usados en toda la guía

Coinciden con las variables del workflow de GitHub Actions.

| Recurso | Nombre |
|---|---|
| Región | `us-east-1` |
| Repositorio ECR | `catalog-service` |
| Cluster | `catalog-service-cluster` |
| Service | `catalog-service` |
| Contenedor | `app` |
| Security groups | `alb-catalog-service-sg`, `app-catalog-service-sg`, `db-catalog-service-sg` |
| Target group | `tg-catalog-service` |
| ALB | `alb-catalog-service` |
| Log group | `/ecs/catalog-service` |
| Parámetro de secreto | `/catalog-service/db-password` |
| Base de datos (dentro de la instancia RDS) | `catalog_db` |
| Instancia RDS | `database-dev` |
| Motor de base de datos | MySQL |
| Rol de ejecución | `ecsTaskExecutionRole` |
| Task definition (family) | `catalog-service` |

Reemplaza `<ACCOUNT_ID>` por tu ID de cuenta de 12 dígitos, `<RDS_ENDPOINT>` por el endpoint de RDS cuando lo tengas y `<ALB_DNS>` por el DNS name del balanceador.

### Nota: si usas nombres distintos a los de esta guía

Puedes nombrar los recursos como prefieras (por ejemplo `api-catalogo` en lugar de `catalog-service`), siempre que todo quede alineado. Revisa que coincidan con lo que realmente creaste:

| Dónde | Qué debe coincidir |
|---|---|
| Task definition, `image` | El nombre de tu repositorio ECR |
| Task definition, `awslogs-group` | El nombre exacto de tu log group (con la barra inicial) |
| Task definition, `valueFrom` | La ruta completa de tu parámetro de SSM |
| Inline policy del rol de ejecución | `parameter/<tu-ruta>/*` debe cubrir ese parámetro |
| Task definition, `executionRoleArn` | El nombre de tu rol de ejecución |
| `SPRING_DATASOURCE_URL` | El endpoint de RDS y el nombre de la base |
| Workflow (módulo 3) | `ECR_REPOSITORY`, `ECS_CLUSTER`, `ECS_SERVICE`, `CONTAINER_NAME` |

El desajuste más común está en la política de SSM: si tu parámetro se llama `/api-catalogo/db-password` y la política sigue apuntando a `parameter/catalog-service/*`, la tarea falla al arrancar con `ResourceInitializationError ... unable to pull secrets`, y parece un error del paso 9.

---

## Requisitos previos de la app

La guía asume que la app del módulo 1 cumple esto. Si no, los pasos 9 y 10 fallan aunque la infraestructura esté perfecta.

1. **Docker instalado** y funcionando en tu máquina (`docker version`).
2. **Dockerfile** que construye la imagen y expone el puerto `8080`; la app escucha en ese puerto.
3. **Actuator** (`spring-boot-starter-actuator`) con `/actuator/health` accesible **sin autenticación**. Si usas Spring Security, permite esa ruta; si no, el health check recibe 401/403 y el target queda `unhealthy`.
4. **Esquema de base de datos (MySQL):** RDS crea una base vacía, sin tablas. Como RDS no es accesible desde tu máquina, la app debe crear sus tablas sola al arrancar. En este MVP se hace con `spring.jpa.hibernate.ddl-auto: update`; en producción real se usan migraciones (opción de Flyway al final de la sección siguiente). Sin esto, `/actuator/health` responde `UP` pero `/products` falla con `Table 'products.<tu_tabla>' doesn't exist`. Se configura en la sección *Base de datos y app en local con Docker*, justo debajo.
5. **Sin credenciales hardcodeadas:** la app recibe la URL, el usuario y la contraseña de la base por variables de entorno (`SPRING_DATASOURCE_URL`, `SPRING_DATASOURCE_USERNAME`, `SPRING_DATASOURCE_PASSWORD`). En `application.yml` se referencian con `${...}` (ver la sección siguiente), así que la misma imagen sirve en tu máquina y en AWS cambiando únicamente esos valores.
6. **VPC por defecto existente:** VPC → *Your VPCs*, columna *Default VPC = Yes*. Si no existe, la guía no aplica tal cual.
7. **Repositorio en GitHub (no hace falta para los pasos 0 a 10):** se necesita desde el módulo 3 (paso 11), porque la trust policy de OIDC nombra tu repositorio (`USUARIO/REPO`) y el workflow vive en `.github/workflows/`. Puedes crearlo ahora, aunque esté vacío.

---

## Base de datos y app en local con Docker (antes de ir a AWS)

> **Qué es y por qué importa**
>
> **Qué es:** probar en tu máquina que la app se conecta a una base MySQL y crea sus tablas, usando las mismas variables de entorno que usará ECS.
>
> 1. **Validas la app antes de gastar en AWS:** driver, URL, tablas, Actuator y que la imagen arranca. Si funciona aquí, el paso 10 solo tiene que comprobar la red y las credenciales reales.
> 2. **RDS no es accesible desde tu máquina** (acceso público desactivado): no puedes crear tablas a mano ni probar la conexión desde tu laptop. Por eso la app debe crear sus propias tablas al arrancar.
> 3. **Una sola imagen para todos los entornos:** lo único que cambia entre local y AWS son tres variables de entorno.

### Qué cambia y qué no

| Pieza | ¿Cambia? | Qué hacer |
|---|---|---|
| `Dockerfile` | **No** | La base de datos no va dentro de la imagen |
| `pom.xml` | Sí | Agregar el driver de MySQL (queda dentro del JAR) |
| `application.yml` | Sí | Referencias a las variables de entorno (`${...}`) y una línea para crear las tablas; **sin** valores reales |
| Variables de entorno | Sí | URL, usuario y contraseña se pasan al ejecutar el contenedor |
| Un MySQL en contenedor | Solo para probar en local | Es un contenedor aparte, no forma parte de tu imagen |
| En AWS | — | La base es RDS; no hay Docker para la base |

### 1) Dependencia (`pom.xml`)

Spring Boot administra la versión, así que no la pongas:

```xml
<dependency>
  <groupId>com.mysql</groupId>
  <artifactId>mysql-connector-j</artifactId>
  <scope>runtime</scope>
</dependency>
```

El driver queda empaquetado dentro del JAR, así que el Dockerfile no necesita nada extra. Si tenías el driver de PostgreSQL (`org.postgresql:postgresql`), quítalo.

### 2) Configuración de la app (`src/main/resources/application.yml`)

El archivo **no contiene valores de conexión**, solo referencias a variables de entorno con la sintaxis `${NOMBRE}` (signo de dólar y llaves).

```yaml
server:
  port: 8080

spring:
  datasource:
    url: ${SPRING_DATASOURCE_URL}
    username: ${SPRING_DATASOURCE_USERNAME}
    password: ${SPRING_DATASOURCE_PASSWORD}
  jpa:
    hibernate:
      ddl-auto: update
    open-in-view: false

management:
  endpoints:
    web:
      exposure:
        include: health
  endpoint:
    health:
      show-details: never
      probes:
        enabled: true
```

**Cómo llegan los valores a la app:**

```
-e de docker run  /  environment y secrets de la task definition
        ↓
variables de entorno del contenedor (SPRING_DATASOURCE_URL, ...)
        ↓
Spring Boot las lee al arrancar y sustituye cada ${...} del application.yml
        ↓
la app se conecta a la base con esos valores
```

- **Quién inyecta:** Docker (con `-e`) en local, y ECS (con `environment` y `secrets` de la task definition) en AWS. El `application.yml` no inyecta nada: solo dice qué variable debe leer.
- **Los nombres deben coincidir** entre el `${...}` del yml y los `-e` o la task definition. Si no coinciden, la app no arranca con `Could not resolve placeholder`.
- **Valor por defecto, opcional:** `${NOMBRE:valor}` usa `valor` si la variable no existe. Útil para URL y usuario locales; no lo uses con contraseñas reales.
- **Atajo que existe, pero no usamos:** Spring Boot también convierte por sí solo `SPRING_DATASOURCE_URL` en la propiedad `spring.datasource.url`, sin mencionarla en el yml, siempre que el nombre sea exactamente ese. Funciona, pero oculta de dónde salen los valores y confunde a quien aprende. Con las referencias explícitas, el yml se lee solo.
- **Prioridad:** si una propiedad está en el yml y también existe como variable de entorno con el nombre estándar de Spring, gana la variable de entorno.

### 3) Cómo se crean las tablas

Una base de datos nueva está vacía: no tiene tablas. Con `ddl-auto: update`, Hibernate crea al arrancar las tablas y columnas que faltan, a partir de tus entidades. Sin esa línea no se crea nada, porque, hasta donde sé, el valor por defecto con una base externa es no hacer nada.

| Opción | Qué hace | Cuándo usarla |
|---|---|---|
| **`ddl-auto: update`** | Hibernate crea las tablas y columnas que faltan; nunca borra nada | **Este MVP.** Es lo más simple |
| Migraciones con Flyway | Scripts SQL versionados que se ejecutan una sola vez | Producción real (ver la opción al final de esta sección) |

`update` es un atajo cómodo para un MVP, pero no es lo que se usa en producción, porque no deja historial de cambios y no puede renombrar ni migrar datos.

Detalles que evitan sorpresas:

- La tabla se llama como la mapee tu entidad. Por defecto, una clase `Product` crea la tabla `product`; si la quieres en plural, usa `@Table(name = "products")`.
- Usa nombres de tabla y columna **en minúsculas**: hasta donde sé, MySQL en RDS (Linux) distingue mayúsculas y minúsculas en los nombres de tabla.
- En AWS las tablas las crea la primera tarea que arranca, con el usuario `admin`, que tiene permisos para hacerlo.

### 4) Un MySQL para probar en local

Es un contenedor **aparte** de tu app. Elige una opción.

**Opción A (mínima): dos comandos `docker run`.**

```bash
docker network create catalog-service-net

docker run -d --name catalog-service-db --network catalog-service-net \
  -e MYSQL_ROOT_PASSWORD=local-root-pass \
  -e MYSQL_DATABASE=catalog_db \
  -e MYSQL_USER=app -e MYSQL_PASSWORD=local-app-pass \
  -p 3306:3306 mysql:8.4
```

Espera unos 20 a 30 segundos hasta que `docker logs catalog-service-db` muestre que está listo para conexiones. Después:

```bash
docker build -t catalog-service:test .

docker run --rm --name catalog-service-app --network catalog-service-net -p 8080:8080 \
  -e SPRING_DATASOURCE_URL="jdbc:mysql://catalog-service-db:3306/catalog_db?allowPublicKeyRetrieval=true&useSSL=false" \
  -e SPRING_DATASOURCE_USERNAME=app \
  -e SPRING_DATASOURCE_PASSWORD=local-app-pass \
  catalog-service:test
```

**Opción B (cómoda): `docker-compose.yml` en la raíz del proyecto**, que levanta ambos contenedores y espera a que MySQL esté listo.

```yaml
services:
  db:
    image: mysql:8.4
    container_name: catalog-service-db
    environment:
      MYSQL_ROOT_PASSWORD: local-root-pass
      MYSQL_DATABASE: catalog_db
      MYSQL_USER: app
      MYSQL_PASSWORD: local-app-pass
    ports:
      - "3306:3306"
    volumes:
      - catalog-service-db-data:/var/lib/mysql
    healthcheck:
      test: ["CMD-SHELL", "mysqladmin ping -h 127.0.0.1 -uroot -p$$MYSQL_ROOT_PASSWORD --silent"]
      interval: 5s
      timeout: 5s
      retries: 20

  app:
    build: .
    container_name: catalog-service-app
    depends_on:
      db:
        condition: service_healthy
    environment:
      SPRING_DATASOURCE_URL: jdbc:mysql://db:3306/catalog_db?allowPublicKeyRetrieval=true&useSSL=false
      SPRING_DATASOURCE_USERNAME: app
      SPRING_DATASOURCE_PASSWORD: local-app-pass
    ports:
      - "8080:8080"

volumes:
  catalog-service-db-data:
```

Se levanta con `docker compose up --build`.

Qué conviene explicar:

- `MYSQL_DATABASE: catalog_db` crea la base vacía al primer arranque, igual que el campo *Initial database name* de RDS. Las tablas las crea Hibernate.
- En la URL, el host es el **nombre del contenedor de la base** (`catalog-service-db` o `db`), no `localhost`: dentro de Docker, `localhost` es el propio contenedor de la app.
- `allowPublicKeyRetrieval=true&useSSL=false` es **solo para este MySQL local**. En RDS no se pone.
- Usa la misma versión mayor de MySQL que elijas en RDS (verifica cuáles ofrece RDS al crear la instancia).
- Si ejecutas la app desde tu IDE en vez de Docker, define esas tres variables de entorno en la configuración de ejecución y usa `localhost` como host.

### 5) Verificar

```bash
curl -i http://localhost:8080/actuator/health        # 200 y {"status":"UP"}
curl -i http://localhost:8080/api/v1/products        # lista vacía hasta que crees un producto
docker exec catalog-service-db mysql -uapp -plocal-app-pass catalog_db -e "SHOW TABLES;"
```

Debe aparecer la tabla de tu entidad (en este proyecto, `products`). Para detener: en la opción A, `docker stop catalog-service-db catalog-service-app` y `docker rm catalog-service-db`; en la opción B, `docker compose down` (conserva los datos) o `docker compose down -v` (los borra).

### 6) Qué cambia entre local y AWS

| Variable | Local (Docker) | AWS (ECS) |
|---|---|---|
| `SPRING_DATASOURCE_URL` | `jdbc:mysql://catalog-service-db:3306/catalog_db?allowPublicKeyRetrieval=true&useSSL=false` | `jdbc:mysql://<RDS_ENDPOINT>:3306/catalog_db` |
| `SPRING_DATASOURCE_USERNAME` | `app` | `admin` (usuario maestro de RDS) |
| `SPRING_DATASOURCE_PASSWORD` | `local-app-pass` | Viene de Parameter Store (`secrets` en la task definition) |

La imagen es la misma en los dos entornos.

### 7) Errores frecuentes en local

| Síntoma | Causa y arreglo |
|---|---|
| `Communications link failure` | MySQL aún está arrancando, o la URL usa `localhost` dentro de Docker en vez del nombre del contenedor |
| `Public Key Retrieval is not allowed` | Falta `allowPublicKeyRetrieval=true` en la URL local |
| `Access denied for user` | Usuario o contraseña distintos entre la app y el contenedor MySQL |
| `Table '...' doesn't exist` | La app no crea las tablas: falta `ddl-auto: update` en `application.yml` |
| `Could not resolve placeholder 'SPRING_DATASOURCE_URL'` | La variable no llegó al contenedor: revisa los `-e` (o `environment` en el compose) y que el nombre coincida con el del yml |
| Puerto 3306 ocupado | Tienes otro MySQL local: detenlo o cambia el mapeo a `"3307:3306"` |

### 8) Opcional: migraciones con Flyway (cuando pases del MVP)

No hace falta para este tutorial. Si más adelante quieres historial de cambios en el esquema:

1. Agrega `org.flywaydb:flyway-core` y `org.flywaydb:flyway-mysql` al `pom.xml` (sin versión; `flyway-mysql` es obligatorio para MySQL).
2. Cambia `ddl-auto: update` por `validate`, para que Hibernate solo compruebe que las tablas coinciden con las entidades.
3. Crea `src/main/resources/db/migration/V1__create_products.sql` (dos guiones bajos tras `V1`) con el `CREATE TABLE` de tu entidad. Cada cambio posterior va en un archivo nuevo (`V2__...`).

---

## Paso 0. Preparación (15 min)

> **Qué es y por qué importa**
>
> Deja la cuenta lista antes de crear nada que cueste dinero o dé acceso.
>
> 1. **MFA en root:** root es el dueño absoluto de la cuenta; si se filtra su contraseña, lo pierdes todo. MFA es la defensa más barata.
> 2. **Presupuesto con alerta:** te avisa antes de que un recurso olvidado genere una factura sorpresa. Va primero porque ALB, Fargate y RDS cobran mientras están encendidos.
> 3. **Acceso de IAM a Billing:** sin esta activación, tu usuario de trabajo no ve costos y tendrías que volver a usar root.
> 4. **Usuario IAM en vez de root:** root se reserva para tareas de la cuenta; el trabajo diario se hace con un usuario que puedes desactivar o borrar sin perder la cuenta.
> 5. **CLI con access key:** la consola sirve para hacer clics; la CLI es necesaria para el `docker login` a ECR. La key es una credencial de larga duración, por eso se borra al final.
> 6. **Región única:** los recursos de AWS son regionales; si cambias de región en la consola, parece que desaparecieron.

1. **MFA en root:** IAM → *Security credentials* → *Assign MFA device*.
2. **Presupuesto:** *Billing and Cost Management* → *Budgets* → *Create budget* → *Use a template* → *Monthly cost budget*. Monto: `10` USD. Agrega tu email.
3. **Acceso de IAM a Billing (como root, una sola vez):** por defecto, un usuario IAM no puede ver Billing aunque tenga `AdministratorAccess`. En la cuenta root: menú de tu cuenta → *Account* → *IAM user and role access to Billing information* → *Edit* → *Activate IAM Access*. Sin esto no podrás revisar costos con tu usuario (paso 12). Verifica el nombre exacto de la opción en tu consola.
4. **Usuario para trabajar (acceso a la consola):** IAM → *Users* → *Create user* → marca *Provide user access to the AWS Management Console*, define una contraseña y, en *Set permissions*, elige *Attach policies directly* y marca la política administrada por AWS `AdministratorAccess` (**solo para el tutorial**; en un entorno real se restringe). Activa MFA también en este usuario. Para entrar usa la URL de inicio de sesión de IAM: `https://<ACCOUNT_ID>.signin.aws.amazon.com/console`. Con este usuario haces todos los clics de los pasos siguientes; no vuelvas a usar root.
5. **CLI (obligatoria, al menos para el paso 1):** instala AWS CLI v2. La CLI no usa tu contraseña de consola, necesita una *access key*: IAM → *Users* → tu usuario → *Security credentials* → *Create access key* → caso de uso *Command Line Interface (CLI)*. Luego ejecuta `aws configure` (Access Key ID, Secret, región `us-east-1`, formato `json`). Esta clave vive solo en tu máquina: no la subas a un repo ni a GitHub. El pipeline usará OIDC, sin claves (módulo 3). **Bórrala al terminar** (paso 12). Verifica:
   ```bash
   aws sts get-caller-identity
   ```
   Debe mostrar tu `Account` y tu usuario.
6. **Región:** esquina superior derecha de la consola → **N. Virginia (us-east-1)**. Si cambias de región, los recursos parecen haber desaparecido.

---

## Paso 1. ECR: repositorio y primera imagen (20 min)

> **Qué es y por qué importa**
>
> **Qué es:** ECR (Elastic Container Registry) es el almacén privado de imágenes Docker de AWS. Equivale a Docker Hub, pero dentro de tu cuenta.
>
> 1. **Sin registro no hay despliegue:** ECS no descarga imágenes de tu laptop, solo de un registro.
> 2. **Es el destino del pipeline:** el job `build-and-push` del módulo 3 sube aquí cada imagen.
> 3. **Tag immutability:** impide sobrescribir una etiqueta ya publicada, así que `:abc123` siempre es exactamente la misma imagen. Da trazabilidad y rollback confiables; por eso se etiqueta con el SHA del commit y no con `latest`.
> 4. **Primera imagen a mano:** ECS la necesita para arrancar el service por primera vez, y te muestra el trabajo manual que el pipeline va a eliminar.
> 5. **Costo:** ECR cobra por almacenamiento (verifica la tarifa vigente), así que se borra el repositorio al final.

**Consola:** ECR → *Repositories* → *Create repository*.

| Campo | Valor |
|---|---|
| Visibility | Private |
| Repository name | `catalog-service` |
| Tag immutability | Enabled |
| Encryption | AES-256 (por defecto) |

Con *Tag immutability* activado no puedes sobrescribir una etiqueta existente. Es la razón para etiquetar con el SHA del commit. El escaneo al subir (*scan on push*) en consolas recientes se configura a nivel de registry (ECR → *Private registry* → *Scanning configuration*); verifica dónde está hoy.

**Subir la primera imagen a mano** (ECS la necesita para arrancar, y te muestra el trabajo manual que el pipeline va a eliminar):

```bash
aws ecr get-login-password --region us-east-1 \
 | docker login --username AWS --password-stdin <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com

docker build --platform linux/amd64 -t catalog-service:v1 .
docker tag catalog-service:v1 <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/catalog-service:v1
docker push <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/catalog-service:v1
```

Usa `v1`, no `latest`: con tag immutability el segundo push de `latest` fallaría.

**Trampa frecuente:** si trabajas desde un Mac con chip M, la imagen sale `arm64` y falla en Fargate con `exec format error`. Por eso se usa `--platform linux/amd64`. El runner `ubuntu-latest` de GitHub es x86_64, así que el pipeline no tendrá este problema.

**Verifica:** ECR → `catalog-service` → debe aparecer la imagen `v1`.

---

## Paso 2. Security groups (10 min)

> **Qué es y por qué importa**
>
> **Qué es:** un firewall virtual que se adjunta a un recurso (ALB, tarea de ECS, base de datos) y decide qué tráfico puede **entrar**. Por defecto bloquea todo y tú abres solo lo necesario. Es *stateful*: si permites una conexión de entrada, la respuesta sale sin otra regla. No tiene costo.
>
> ```
> Internet ──80──▶ [alb-catalog-service-sg] ALB ──8080──▶ [app-catalog-service-sg] Tarea ECS ──3306──▶ [db-catalog-service-sg] RDS
> ```
>
> 1. **Seguridad por capas:** solo el ALB está expuesto a internet. Nadie llega a tu app ni a la base directamente, aunque conozca la IP.
> 2. **Por qué las reglas apuntan a otro security group y no a una IP:** las tareas de Fargate cambian de IP en cada despliegue. Una regla por IP se rompería; una regla "desde `alb-catalog-service-sg`" siempre es válida.
> 3. **La IP pública de la tarea no es una puerta abierta:** existe solo para descargar la imagen de ECR, y `app-catalog-service-sg` solo acepta tráfico del ALB.
> 4. **Causa de errores frecuentes:** si `app-catalog-service-sg` no acepta 8080 desde `alb-catalog-service-sg`, el target queda `unhealthy`; si `db-catalog-service-sg` no acepta 3306 desde `app-catalog-service-sg`, la app da timeout contra la base.
> 5. **Error típico:** abrir 3306 a `0.0.0.0/0` "para que funcione". Expone la base a internet y rompe la seguridad por capas.

EC2 → *Security Groups* → *Create security group*. Créalos **en este orden**, porque cada uno referencia al anterior. VPC: la **default** en los tres. Los nombres no pueden empezar con `sg-` (AWS reserva ese prefijo para los IDs de los security groups), por eso usan el sufijo `-sg`.

**1) `alb-catalog-service-sg`**
- Inbound: Type *HTTP*, Port `80`, Source *Anywhere-IPv4* (`0.0.0.0/0`).
- Outbound: por defecto.

**2) `app-catalog-service-sg`**
- Inbound: Type *Custom TCP*, Port `8080`, Source: **Custom** y selecciona `alb-catalog-service-sg` (aparece al escribir `alb`).
- Outbound: por defecto (all traffic). Lo necesita para llegar a ECR, SSM, CloudWatch y RDS.

**3) `db-catalog-service-sg`**
- Inbound: Type *MYSQL/Aurora*, Port `3306`, Source: **Custom** → `app-catalog-service-sg`.

**Verifica:** en `app-catalog-service-sg`, la fuente debe mostrarse como el ID de `alb-catalog-service-sg`, no como una IP.

---

## Paso 3. Logs (3 min)

> **Qué es y por qué importa**
>
> **Qué es:** un grupo de logs en CloudWatch, donde AWS guarda lo que tu aplicación imprime por consola. Spring Boot escribe en la salida estándar del contenedor y el driver `awslogs` de la task definition lo envía aquí.
>
> 1. **En Fargate no hay servidor al que entrar:** no hay SSH ni archivos que mirar. Los logs son casi la única forma de saber por qué falló una tarea.
> 2. **Casi toda la tabla de errores de esta guía se diagnostica con logs:** `exec format error`, `Unknown database 'catalog_db'`, `Communications link failure` a la BD.
> 3. **Debe existir antes:** si el grupo no existe cuando ECS arranca la tarea, esta falla al iniciar. Hasta donde sé, `AmazonECSTaskExecutionRolePolicy` permite escribir logs pero no crear el grupo; verifícalo la primera vez que ejecutes la guía.
> 4. **La retención controla el costo:** por defecto un grupo de logs nunca expira y se cobra por volumen ingerido y almacenamiento (revisa las tarifas vigentes). Con 1 semana no se acumulan para siempre.
> 5. **Qué ver:** el nombre debe ser idéntico al `awslogs-group` de la task definition (`/ecs/catalog-service`, con la barra inicial) y estar en `us-east-1`. No se deben loguear contraseñas ni datos sensibles.

CloudWatch → *Log groups* → *Create log group*.

- Name: `/ecs/catalog-service`
- Retention: **1 week**

O por CLI:

```bash
aws logs create-log-group --log-group-name /ecs/catalog-service
aws logs put-retention-policy --log-group-name /ecs/catalog-service --retention-in-days 7
```

---

## Paso 4. Secreto de la base de datos (5 min)

> **Qué es y por qué importa**
>
> **Qué es:** Parameter Store (dentro de Systems Manager) guarda valores de configuración, y el tipo `SecureString` los cifra con KMS. Aquí guardas la contraseña de la base de datos.
>
> 1. **Nunca en el código:** una contraseña en el repo, el Dockerfile o la task definition en texto plano termina filtrada. Con `secrets` en la task definition, ECS la lee al arrancar y la inyecta como variable de entorno; la contraseña no aparece en tus archivos.
> 2. **Acceso controlado por IAM:** solo el rol de ejecución con permiso `ssm:GetParameters` puede leerla.
> 3. **Costo:** hasta donde sé, los parámetros estándar son gratuitos, mientras que Secrets Manager cobra por secreto y añade rotación. Verifica los precios vigentes.
> 4. **Qué no es secreto:** el usuario y la URL de la base van como variables de entorno normales en la task definition.

Systems Manager → *Parameter Store* → *Create parameter*.

| Campo | Valor |
|---|---|
| Name | `/catalog-service/db-password` |
| Tier | Standard |
| Type | **SecureString** |
| KMS key | `alias/aws/ssm` (por defecto) |
| Value | la contraseña que usarás en RDS |

CLI equivalente:

```bash
aws ssm put-parameter --name /catalog-service/db-password \
  --type SecureString --value 'TU_PASSWORD_AQUI'
```

El usuario y la URL de la BD no son secretos: irán como variables de entorno normales en la task definition.

**Elige la contraseña con cuidado:** hasta donde sé, RDS no acepta `/`, `"`, `@` ni espacios en la contraseña maestra (te avisará al crear la base). Defínela ahora para que coincida en el paso 5. Además, con el comando CLI la contraseña queda en el historial de tu terminal; para el tutorial es preferible usar la consola.

---

## Paso 5. RDS MySQL (15 min, más 5-10 de espera)

> **Qué es y por qué importa**
>
> **Qué es:** RDS es MySQL administrado por AWS: backups, parches y almacenamiento sin que montes un servidor.
>
> 1. **Los datos viven fuera del contenedor:** las tareas de Fargate son efímeras; lo que se guarde dentro se pierde en cada despliegue.
> 2. **Public access: No + `db-catalog-service-sg`:** la base solo es alcanzable desde tu app, no desde internet. Es la última capa de la seguridad por capas del paso 2.
> 3. **Initial database name:** sin él, RDS crea el servidor pero no la base `catalog_db`, y la app falla al conectar.
> 4. **Single-AZ, `db.t4g.micro`, sin autoescalado ni Performance Insights:** decisiones de costo para el tutorial. En producción real se usaría Multi-AZ. RDS cobra mientras esté encendida.
> 5. **Deletion protection desmarcado:** si no, no podrás borrarla en el paso 12.

RDS → *Create database*.

| Sección | Campo | Valor |
|---|---|---|
| Choose a method | | **Full configuration** (en consolas anteriores aparece como *Standard create*). **No uses *Easy create***: oculta campos que esta guía necesita |
| Engine | Type / Version | MySQL / una versión 8.x estable (usa la misma versión mayor en tu MySQL local) |
| Templates | | **Dev/Test** (si ves *Free tier*, revisa qué cubre hoy en cuentas nuevas antes de decir "gratis") |
| Availability | | **Single-AZ** (sin standby) |
| Settings | DB instance identifier | `database-dev` |
| | Master username | `admin` |
| | Credentials management | Self managed; password = la del paso 4 |
| Instance | Class | Burstable → `db.t4g.micro` |
| Storage | Type / Size | gp3 / `20` GiB; **desmarca** *Enable storage autoscaling* |
| Connectivity | Compute resource | *Don't connect to an EC2 compute resource* |
| | VPC | Default |
| | **Public access** | **No** |
| | VPC security group | *Choose existing* → quita `default` y agrega `db-catalog-service-sg` |
| Additional configuration (sección **plegada**: ábrela) | **Initial database name** | `catalog_db` |
| | Backup retention | `1` día (o desactiva en el tutorial) |
| | Deletion protection | **Desmarcado** (si no, no podrás borrarla en la lección de limpieza) |

Desactiva *Performance Insights* y *Enhanced monitoring* para no sumar costo.

El campo **Initial database name** es el que más se pasa por alto: está dentro de una sección plegada y *Easy create* no lo muestra. Si lo dejas vacío, RDS no crea la base `catalog_db` y la app falla con `Unknown database 'catalog_db'`.

Cuando el estado sea **Available**, entra a la instancia → *Connectivity & security* y copia el **Endpoint**. Tu URL JDBC será:

```
jdbc:mysql://<RDS_ENDPOINT>:3306/catalog_db
```

---

## Paso 6. Target group y ALB (15 min)

> **Qué es y por qué importa**
>
> **Qué es:** el ALB (Application Load Balancer) es la puerta de entrada HTTP: recibe las peticiones de internet y las reparte a tus tareas. El target group es la lista de destinos a los que reenvía, junto con la comprobación de salud que decide si cada uno está sano.
>
> 1. **Dirección estable:** las tareas de Fargate cambian de IP en cada despliegue; el ALB ofrece un DNS que no cambia.
> 2. **Health check a `/actuator/health`:** el ALB solo manda tráfico a tareas sanas. También es lo que hace fallar un despliegue defectuoso en vez de dejarlo recibiendo tráfico.
> 3. **Target type IP:** es obligatorio con Fargate, porque cada tarea tiene su propia interfaz de red.
> 4. **Mínimo 2 zonas de disponibilidad:** es un requisito del ALB y la base de la alta disponibilidad.
> 5. **Deregistration delay de 30 s:** con el valor por defecto (300 s) cada deploy tarda unos 5 minutos más mientras se drenan conexiones.
> 6. **El `503` inicial es normal:** aún no hay targets registrados.

### 6.1 Target group

EC2 → *Target Groups* → *Create target group*.

| Campo | Valor |
|---|---|
| Target type (*Tipo de destino*) | **IP addresses** (*Direcciones IP*), obligatorio con Fargate. **No es el valor por defecto** (la consola preselecciona *Instances*) y **no se puede cambiar después de crear el grupo** |
| IP address type (*Tipo de dirección IP*), si aparece | IPv4 |
| Name | `tg-catalog-service` |
| Protocol : Port | HTTP : `8080` |
| VPC | Default |
| Protocol version | HTTP1 |
| Health check path | `/actuator/health` |

En *Advanced health check settings*:

- Healthy threshold: `2`
- Unhealthy threshold: `3`
- Timeout: `5` s, Interval: `15` s
- Success codes: `200`

En la pantalla siguiente (*Register targets*) **no agregues nada** y crea el grupo. Luego entra al target group → *Attributes* → *Edit* → **Deregistration delay: `30` segundos** (el valor por defecto de 300 s hace que cada deploy tarde 5 minutos más).

### 6.2 Load balancer

EC2 → *Load Balancers* → *Create load balancer* → **Application Load Balancer**.

| Campo | Valor |
|---|---|
| Name | `alb-catalog-service` |
| Scheme | Internet-facing |
| IP address type | IPv4 |
| VPC | Default |
| Mappings | marca **al menos 2 zonas de disponibilidad** y anota cuáles: en el paso 9 el service debe usar solo esas subredes |
| Security groups | quita `default` y deja solo `alb-catalog-service-sg` |
| Listener | HTTP : `80` → *Forward to* `tg-catalog-service` |

Al crearlo, copia el **DNS name** (`alb-catalog-service-xxxx.us-east-1.elb.amazonaws.com`). Si lo abres ahora verás `503`: es lo esperado, aún no hay tareas.

---

## Paso 7. Cluster ECS (2 min)

> **Qué es y por qué importa**
>
> **Qué es:** el cluster es el agrupador lógico donde corren tus services. Con Fargate no administras servidores, así que es casi un nombre y un espacio de organización.
>
> 1. **Contenedor de nivel superior:** el service del paso 9 se crea dentro de él, y el workflow lo referencia con `ECS_CLUSTER`.
> 2. **Solo Fargate:** no hay instancias EC2 que parchear ni dimensionar; pagas por la CPU y la memoria de las tareas.
> 3. **Container Insights apagado:** genera métricas con costo adicional y no lo necesitas para el tutorial.

ECS → *Clusters* → *Create cluster*.

- Cluster name: `catalog-service-cluster`
- Infrastructure: **AWS Fargate (serverless)** únicamente
- Monitoring: deja *Container Insights* apagado (genera costo)

---

## Paso 8. Execution role y task definition (25 min)

> **Qué es y por qué importa**
>
> **Qué es:** son dos piezas. El *rol de ejecución* es la identidad que ECS usa para preparar tu tarea (descargar la imagen, escribir logs, leer el secreto). La *task definition* es la receta del contenedor: imagen, CPU, memoria, puerto, variables y logs.
>
> 1. **Separación de permisos:** el rol de ejecución es de ECS, no de tu app. Tu código no recibe permisos de AWS; por eso no hay task role.
> 2. **Es el archivo que el pipeline modifica:** en cada despliegue reemplaza solo la imagen y registra una revisión nueva. Por eso se guarda en el repo como `.aws/task-definition.json`.
> 3. **Memoria de 1 GB:** con 512 MB, Spring Boot suele morir por falta de memoria (código 137).
> 4. **`secrets` vs `environment`:** lo sensible viene de Parameter Store; lo demás va como variable normal.
> 5. **Escribirla a mano en vez de exportarla:** al exportar, AWS añade campos de solo lectura que complican el paso de render del pipeline.
> 6. **`name: "app"` debe coincidir con `CONTAINER_NAME` del workflow:** el pipeline localiza el contenedor por ese nombre.

### 8.1 Rol de ejecución

Créalo **antes** de registrar la task definition (8.2), porque esta lo referencia por ARN; sin el rol, las tareas no podrán arrancar. Si en tu cuenta ya existe un rol llamado `ecsTaskExecutionRole` (por ejemplo, creado antes desde la consola de ECS), no lo recrees: comprueba que tenga `AmazonECSTaskExecutionRolePolicy` y agrega solo la inline policy de abajo.

IAM → *Roles* → *Create role*.

- Trusted entity: *AWS service* → Use case: **Elastic Container Service** → **Elastic Container Service Task**.
- Policy: `AmazonECSTaskExecutionRolePolicy`.
- Role name: `ecsTaskExecutionRole`.

Con la política administrada que acabas de adjuntar, el rol puede descargar la imagen de ECR y escribir logs, pero **no puede leer Parameter Store**. Como la task definition pide la contraseña con `secrets`, ECS necesita ese permiso extra al arrancar la tarea; sin él, la tarea falla con `ResourceInitializationError ... unable to pull secrets`.

Se lo das con una *inline policy*: una política pequeña que vive **dentro de este mismo rol** (no es un rol nuevo) y que solo permite leer los parámetros bajo `/catalog-service/`. El asistente de creación del rol solo deja adjuntar políticas que ya existen, por eso esta se agrega **después**, en el rol ya creado:

1. IAM → *Roles* → abre `ecsTaskExecutionRole`.
2. Pestaña *Permissions* → *Add permissions* → *Create inline policy*.
3. Cambia a la pestaña **JSON**, borra el contenido y pega la política de abajo (con tu `<ACCOUNT_ID>`).
4. *Next* → nombre `leer-secretos-catalog-service` → *Create policy*.

Política a pegar:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["ssm:GetParameters"],
    "Resource": "arn:aws:ssm:us-east-1:<ACCOUNT_ID>:parameter/catalog-service/*"
  }]
}
```

Como el parámetro usa la clave por defecto `alias/aws/ssm`, no necesitas permisos de KMS. Si algún día usas una clave propia, sí.

**Verifica:** el rol debe mostrar dos políticas, `AmazonECSTaskExecutionRolePolicy` y tu inline policy. El `Resource` de la inline policy debe cubrir la ruta de tu parámetro (`/catalog-service/db-password`).

### 8.2 Task definition escrita a mano

> **Antes de registrarla:** revisa la tabla *Nota: si usas nombres distintos a los de esta guía* del inicio. Cualquier nombre que no coincida con lo que creaste hace fallar la tarea.

**Qué haces en este paso:** (a) creas un archivo JSON en tu proyecto, (b) reemplazas los marcadores por tus valores, (c) compruebas tres cosas, (d) lo registras en ECS y (e) verificas que quedó registrado.

**De dónde sale cada valor de la task definition:**

| Campo | Valor | Viene de |
|---|---|---|
| `image` | `<ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/catalog-service:v1` | Paso 1 (repositorio y primera imagen) |
| `SPRING_DATASOURCE_URL` | `jdbc:mysql://<RDS_ENDPOINT>:3306/catalog_db` | Paso 5 (endpoint y *Initial database name*) |
| `SPRING_DATASOURCE_USERNAME` | `admin` | Paso 5 (*Master username*) |
| `valueFrom` | `arn:aws:ssm:us-east-1:<ACCOUNT_ID>:parameter/catalog-service/db-password` | Paso 4 (parámetro de SSM) |
| `awslogs-group` | `/ecs/catalog-service` | Paso 3 (log group) |
| `executionRoleArn` | `arn:aws:iam::<ACCOUNT_ID>:role/ecsTaskExecutionRole` | Paso 8.1 |
| `name` del contenedor | `app` | Debe coincidir con `CONTAINER_NAME` del workflow (módulo 3) |

Escríbela tú en vez de exportarla: así evitas los campos de solo lectura que AWS agrega al exportar (`taskDefinitionArn`, `revision`, `status`, etc.) y que complican el paso de render del pipeline.

**a) Crea el archivo.** En la raíz de tu proyecto (junto al `pom.xml`) crea la carpeta **`.aws`** (el punto inicial es parte del nombre: con `aws` a secas, el pipeline del módulo 3 no encuentra el archivo y falla con `Task definition file does not exist`) y, dentro, el archivo `task-definition.json` con este contenido. Es solo un archivo de texto: apunta a la imagen que ya subiste a ECR en el paso 1, no la contiene. Va en tu repositorio Git (el de GitHub, no el de ECR) porque el pipeline (módulo 3) lo usa en cada despliegue:

```json
{
  "family": "catalog-service",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "512",
  "memory": "1024",
  "runtimePlatform": {
    "cpuArchitecture": "X86_64",
    "operatingSystemFamily": "LINUX"
  },
  "executionRoleArn": "arn:aws:iam::<ACCOUNT_ID>:role/ecsTaskExecutionRole",
  "containerDefinitions": [
    {
      "name": "app",
      "image": "<ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/catalog-service:v1",
      "essential": true,
      "portMappings": [
        { "containerPort": 8080, "protocol": "tcp" }
      ],
      "environment": [
        { "name": "SPRING_DATASOURCE_URL", "value": "jdbc:mysql://<RDS_ENDPOINT>:3306/catalog_db" },
        { "name": "SPRING_DATASOURCE_USERNAME", "value": "admin" }
      ],
      "secrets": [
        {
          "name": "SPRING_DATASOURCE_PASSWORD",
          "valueFrom": "arn:aws:ssm:us-east-1:<ACCOUNT_ID>:parameter/catalog-service/db-password"
        }
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/catalog-service",
          "awslogs-region": "us-east-1",
          "awslogs-stream-prefix": "ecs"
        }
      }
    }
  ]
}
```

Puntos clave de este archivo:

- `cpu: 512` y `memory: 1024` son 0.5 vCPU y 1 GB. Con 512 MB, Spring Boot suele morir por falta de memoria (código 137).
- El límite de memoria de la JVM (`-XX:MaxRAMPercentage=75`) va en el `ENTRYPOINT` del Dockerfile, no en la task definition.
- `secrets` inyecta la contraseña como variable de entorno sin escribirla en el archivo.
- `name: "app"` debe ser idéntico a `CONTAINER_NAME` del workflow.
- Este archivo contiene tu Account ID y el endpoint de RDS. No son secretos (la contraseña va por SSM), pero tenlo presente si tu repositorio de GitHub es público.

**b) Reemplaza los marcadores.** El archivo tiene dos marcadores que debes sustituir por tus valores reales: `<ACCOUNT_ID>` (aparece 3 veces: `image`, `executionRoleArn` y `valueFrom`) y `<RDS_ENDPOINT>` (1 vez, en la URL de la base de datos). Tu ID de cuenta lo obtienes con:

```bash
aws sts get-caller-identity --query Account --output text
```

Después confirma que no quedó ningún marcador y que el JSON es válido (en Windows, busca el carácter `<` con tu editor):

```bash
grep -n "<" .aws/task-definition.json
python3 -m json.tool .aws/task-definition.json > /dev/null && echo "JSON válido"
```

El primer comando no debe imprimir nada.

**c) Comprueba antes de registrarla:**

1. **La imagen `v1` existe** en tu repositorio `catalog-service` (ECR → `catalog-service` → *Images*). Si en el paso 1 subiste otra etiqueta, cámbiala aquí.
2. **El contenedor se llama `app`**, y ese nombre será el `CONTAINER_NAME` del workflow (módulo 3).
3. **El valor del parámetro `/catalog-service/db-password` es exactamente la contraseña de la instancia RDS.** Si difieren, la tarea arranca pero falla al conectar con la base de datos.

**d) Regístrala en ECS (consola).**

1. ECS → *Task definitions*, en el menú lateral.
2. Abre el menú desplegable del botón *Create new task definition* y elige **Create new task definition with JSON** (la primera opción abre un formulario, no te sirve).
3. Borra el contenido del editor, pega tu JSON con los valores reales y pulsa *Create*.

Si el editor marca un error, revisa que no queden marcadores `<...>`, que no falten comas o llaves, y que el rol del paso 8.1 exista.

Alternativa por CLI, desde la raíz del proyecto:

```bash
aws ecs register-task-definition --cli-input-json file://.aws/task-definition.json
```

**e) Verifica:** ECS → *Task definitions* → `catalog-service` debe mostrar la revisión 1 en estado *ACTIVE*. Cada despliegue del pipeline registrará una revisión nueva.

---

## Paso 9. Service (15 min)

> **Qué es y por qué importa**
>
> **Qué es:** el service mantiene corriendo el número de tareas que pides (aquí 1), las reemplaza si mueren y las conecta al ALB. Es el recurso que el pipeline actualiza en cada despliegue.
>
> 1. **Convierte la receta en una app accesible:** la task definition por sí sola no ejecuta nada.
> 2. **Rolling update 100%/200%:** arranca la tarea nueva antes de parar la vieja, para no tener caída durante el despliegue.
> 3. **Circuit breaker con rollback:** si el despliegue nuevo no queda sano, ECS vuelve solo a la versión anterior.
> 4. **Health check grace period (90 s):** da tiempo a Spring Boot para arrancar antes de que el ALB lo juzgue.
> 5. **Public IP activada + `app-catalog-service-sg`:** sin NAT, la tarea necesita IP pública para llegar a ECR; `app-catalog-service-sg` evita que alguien entre por ella.

ECS → `catalog-service-cluster` → *Services* → *Create*.

**Environment**

- Compute options: *Launch type* → **FARGATE**, platform version *LATEST*.

**Deployment configuration**

- Application type: *Service*
- Family: `catalog-service`, Revision: *LATEST*
- Service name: `catalog-service`
- Desired tasks: `1`

**Deployment options**

- Deployment type: *Rolling update*
- Min running tasks %: `100`, Max running tasks %: `200`
- Deployment failure detection: marca **Use the Amazon ECS deployment circuit breaker** y **Rollback on failures**

**Networking**

- VPC: Default; subnets: **solo las que marcaste en el ALB** (paso 6.2). La consola preselecciona todas las subredes de la VPC: quita las demás. ECS coloca la tarea en cualquiera de las subredes de la lista, y si cae en una zona donde el ALB no está, el target queda `unhealthy` con el motivo *Target is in an Availability Zone that is not enabled for the load balancer*. Compara con `aws elbv2 describe-load-balancers --names alb-catalog-service --query "LoadBalancers[0].AvailabilityZones[].SubnetId"`
- Security group: quita `default` y deja **`app-catalog-service-sg`**
- **Public IP: Turned on** (sin NAT Gateway, la tarea necesita IP pública para descargar la imagen de ECR)

**Load balancing**

- Type: Application Load Balancer → *Use an existing load balancer* → `alb-catalog-service`
- Container: `app 8080:8080`
- Listener: *Use an existing listener* → `80:HTTP`
- Target group: *Use an existing target group* → `tg-catalog-service`
- **Health check grace period: `90` segundos** (está en esta misma sección; Spring Boot tarda en arrancar y sin esto ECS mata la tarea antes de tiempo)

Crea el service. Tarda unos minutos.

---

## Paso 10. Verificación (5 min)

> **Qué es y por qué importa**
>
> **Qué es:** la comprobación de que toda la cadena funciona de punta a punta: la tarea corre, el ALB la ve sana y la app responde.
>
> 1. **Cada capa falla distinto:** tarea (`RUNNING`), balanceador (`healthy`) y app (respuesta real). Verificar en ese orden te dice dónde mirar.
> 2. **Es tu punto de referencia:** si esto funciona a mano, cualquier fallo posterior del pipeline será del pipeline y no de la infraestructura.
> 3. **Los comandos de diagnóstico** de este paso son los que usarás para cualquier error del módulo.

**1) Estado del service:** ECS → `catalog-service` → pestaña *Tasks*: debe pasar a **RUNNING**.

**2) Target group:** EC2 → `tg-catalog-service` → pestaña *Targets*: estado **healthy** (puede tardar 1-2 minutos).

**3) Prueba real:**

```bash
curl http://<ALB_DNS>/actuator/health
# {"status":"UP"}
curl http://<ALB_DNS>/api/v1/products
```

**4) Si algo falla, estos comandos te dicen por qué:**

```bash
# Últimos eventos del service
aws ecs describe-services --cluster catalog-service-cluster --services catalog-service \
  --query 'services[0].events[:5].message'

# Logs de la app en vivo
aws logs tail /ecs/catalog-service --follow

# Tareas detenidas (consola: Tasks → Stopped → "Stopped reason")
aws ecs list-tasks --cluster catalog-service-cluster --desired-status STOPPED
```

---

## Errores reales y cómo diagnosticarlos

| Síntoma | Dónde mirar | Causa y arreglo |
|---|---|---|
| `CannotPullContainerError` | *Stopped reason* de la tarea | Public IP apagada, o la imagen/etiqueta no existe en ECR |
| `ResourceInitializationError ... unable to pull secrets` | *Stopped reason* | Falta la inline policy `ssm:GetParameters`, o el ARN del parámetro está mal escrito |
| `exec format error` en logs | CloudWatch | Imagen `arm64` en una task `X86_64`. Reconstruye con `--platform linux/amd64` |
| Código de salida 137 | *Stopped reason* | Sin memoria. Sube `memory` a 1024 o más |
| `Communications link failure` o timeout a la BD | Logs de la app | `db-catalog-service-sg` no permite 3306 desde `app-catalog-service-sg`, o la URL JDBC / el endpoint es incorrecto |
| `Unknown database 'catalog_db'` | Logs de la app | No pusiste *Initial database name* en RDS |
| `Access denied for user` | Logs de la app | El parámetro de SSM no coincide con la contraseña de RDS, o el usuario no es `admin` |
| `Could not resolve placeholder 'SPRING_DATASOURCE_...'` | Logs de la app | La variable no llegó al contenedor: revisa `environment` y `secrets` de la task definition y que los nombres coincidan con el yml |
| `Table 'products.<tu_tabla>' doesn't exist` | Logs de la app | La app no crea las tablas al arrancar: revisa `ddl-auto: update` (o Flyway, si lo usas); ver la sección de Docker local |
| Target `unhealthy` | Target group → *Targets* | Path o puerto mal, `app-catalog-service-sg` no acepta 8080 desde `alb-catalog-service-sg`, o grace period muy corto |
| `Target is in an Availability Zone that is not enabled for the load balancer` | *Events* del service | El service tiene subredes en zonas donde el ALB no está, y ECS puso la tarea en una de ellas. Deja en el service solo las subredes del ALB (paso 9). La alternativa es agregar esas zonas al ALB; verifica antes el costo adicional del balanceador |
| `503` en el ALB | Navegador | No hay targets sanos todavía |
| La tarea se reinicia en bucle | *Events* del service | Falla el health check: revisa logs y grace period |

---

## Paso 11. Rol de AWS para GitHub Actions (OIDC), inicio del módulo 3

> **Qué es y por qué importa**
>
> **Qué es:** la primera lección del módulo 3. Define qué puede hacer en tu cuenta el rol que asumirá GitHub Actions.
>
> 1. **Mínimo privilegio donde sí importa:** el pipeline corre sin supervisión, así que solo debe poder subir imágenes al repositorio y actualizar el service.
> 2. **OIDC:** GitHub obtiene credenciales temporales para ese rol, sin claves de AWS guardadas en GitHub Secrets. Es el diferencial frente a los tutoriales que usan claves estáticas.
> 3. **Trust policy:** decide qué repositorio, rama o environment puede asumir el rol. Es la diferencia entre "cualquier repo" y "solo el tuyo".
> 4. **`iam:PassRole` limitado al rol de ejecución:** sin él, el pipeline no puede registrar la task definition; al limitarlo, no puede pasar roles más poderosos.

Este paso se hace en **IAM** (no en ECS ni en GitHub) y tiene tres piezas: un proveedor de identidad (11.1), un rol (11.2) y un secreto en GitHub (11.3). Necesitas el repositorio de GitHub ya creado, porque el rol lleva escrito `USUARIO/REPO` (distingue mayúsculas y minúsculas) y, si el repositorio se creó después del 15 de julio de 2026, también los IDs numéricos del dueño y del repositorio (ver 11.2b).

### 11.1 Proveedor de identidad (una sola vez por cuenta)

IAM → *Identity providers* → *Add provider* → tipo **OpenID Connect**:

| Campo | Valor |
|---|---|
| Provider URL | `https://token.actions.githubusercontent.com` |
| Audience | `sts.amazonaws.com` |

Pulsa *Add provider* (si la consola ofrece *Get thumbprint*, úsalo). Debe aparecer `token.actions.githubusercontent.com` en la lista. Esto le dice a AWS que confíe en los tokens que emite GitHub.

### 11.2 Rol que asumirá GitHub Actions

**a) Crear el rol.** IAM → *Roles* → *Create role*:

1. *Trusted entity type*: **Web identity**.
2. *Identity provider*: `token.actions.githubusercontent.com`. *Audience*: `sts.amazonaws.com`. Si la consola pide organización, repositorio y rama de GitHub, escribe tu usuario, tu repositorio y `main`.
3. No adjuntes políticas todavía.
4. Nombre del rol: `github-actions-catalog-service`.

**b) Editar la trust policy.** La que genera la consola solo acepta la rama indicada. Pero si el job de deploy usa `environment: production` (como en el workflow del módulo 3), el token de GitHub trae un `sub` con formato de environment, no de rama; el job de build, sin environment, usa el formato de rama. La condición debe aceptar ambos.

**Formato del `sub` según la fecha de creación del repositorio.** GitHub cambió el formato por defecto. Los repositorios creados **después del 15 de julio de 2026** (y los que se renombren o transfieran después de esa fecha) usan un `sub` inmutable que incluye los IDs numéricos del dueño y del repositorio. Los anteriores conservan el formato clásico:

| Repositorio | `sub` de la rama `main` |
|---|---|
| Clásico (anterior al 15/07/2026) | `repo:USUARIO/REPO:ref:refs/heads/main` |
| Inmutable (nuevo) | `repo:USUARIO@OWNER_ID/REPO@REPO_ID:ref:refs/heads/main` |

Usa el que corresponda a tu repositorio. Si pones el formato equivocado, AWS no encuentra coincidencia y responde `Not authorized to perform sts:AssumeRoleWithWebIdentity`. Para obtener los IDs (necesitas `gh` autenticado):

```bash
gh api repos/USUARIO/REPO --jq '{repo_id: .id, owner_id: .owner.id}'
```

Para ver el `sub` real que envía GitHub, usa el paso de depuración de la sección 11.5.

Rol → *Trust relationships* → *Edit trust policy* (el ejemplo está en formato inmutable):

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
      },
      "StringLike": {
        "token.actions.githubusercontent.com:sub": [
          "repo:USUARIO@OWNER_ID/REPO@REPO_ID:ref:refs/heads/main",
          "repo:USUARIO@OWNER_ID/REPO@REPO_ID:environment:production"
        ]
      }
    }
  }]
}
```

Reemplaza `<ACCOUNT_ID>`, `USUARIO`, `OWNER_ID`, `REPO` y `REPO_ID`. Si tu repositorio es anterior al 15 de julio de 2026 y usa el formato clásico, quita `@OWNER_ID` y `@REPO_ID` de ambas líneas. El nombre del environment (`production`) debe coincidir con el de GitHub, letra por letra. Si falta uno de los dos formatos (rama o environment), el síntoma es `Not authorized to perform sts:AssumeRoleWithWebIdentity` en ese job.

**No agregues ramas extra** (por ejemplo `feature/...`) a esta lista. Cada línea de `sub` amplía quién puede asumir un rol que sube imágenes y actualiza el service; el pipeline solo necesita `main` y el environment `production`.

**c) Permisos mínimos.** El rol necesita:

- **ECR:** `GetAuthorizationToken` y, sobre el repositorio `catalog-service`: `BatchCheckLayerAvailability`, `InitiateLayerUpload`, `UploadLayerPart`, `CompleteLayerUpload`, `PutImage` y `BatchGetImage`.
- **ECS:** `RegisterTaskDefinition`, `DescribeTaskDefinition`, `DescribeServices`, `UpdateService`.
- **IAM:** `PassRole` limitado al ARN de `ecsTaskExecutionRole`.

Rol → *Permissions* → *Add permissions* → *Create inline policy* → pestaña **JSON**. Nombre sugerido: `desplegar-catalog-service`.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "ecr:GetAuthorizationToken",
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload",
        "ecr:PutImage",
        "ecr:BatchGetImage"
      ],
      "Resource": "arn:aws:ecr:us-east-1:<ACCOUNT_ID>:repository/catalog-service"
    },
    {
      "Effect": "Allow",
      "Action": [
        "ecs:RegisterTaskDefinition",
        "ecs:DescribeTaskDefinition"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "ecs:DescribeServices",
        "ecs:UpdateService"
      ],
      "Resource": "arn:aws:ecs:us-east-1:<ACCOUNT_ID>:service/catalog-service-cluster/catalog-service"
    },
    {
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "arn:aws:iam::<ACCOUNT_ID>:role/ecsTaskExecutionRole"
    }
  ]
}
```

Las acciones de task definition llevan `*` porque, hasta donde sé, no admiten recursos específicos. Si al ejecutar el pipeline aparece `AccessDenied`, el mensaje nombra la acción y el recurso que faltan: agrégalos aquí, de uno en uno y solo los que el mensaje nombre. No agregues por adelantado acciones que ningún error ha pedido (por ejemplo `ecr:DescribeRepositories` o `ecr:ListImages`): cada una amplía lo que el rol puede hacer sobre el repositorio.

### 11.3 Configurar secretos en GitHub

> **Qué es y por qué importa**
>
> **Qué es:** tres piezas en GitHub que el workflow referencia: el secreto con el ARN del rol, el environment `production` y una variable con el DNS del ALB.
>
> 1. **El environment `production` no es decorativo:** el nombre aparece en la trust policy (`environment:production`). Si no coincide letra por letra, el job `deploy` no puede asumir el rol.
> 2. **`ALB_DNS` va como variable, no como secreto:** no es sensible, y los secretos se enmascaran en los logs, lo que dificulta depurar.
> 3. **Antes de escribir el workflow:** así el primer push ya encuentra todo.

En GitHub → tu repositorio → *Settings*:

1. **Secreto `AWS_ROLE_ARN`:** Copia el **ARN del rol** (está en su página de IAM: `arn:aws:iam::<ACCOUNT_ID>:role/github-actions-catalog-service`). En GitHub: repositorio → *Settings* → *Secrets and variables* → *Actions* → *New repository secret*, con el nombre `AWS_ROLE_ARN`. No es una clave de acceso: es solo la dirección del rol, y por eso no hay claves de AWS en GitHub.
2. **Environment:** *Environments* → *New environment* → nombre exacto **`production`** → *Configure environment*. No agregues reglas por ahora. (Opcional: *Required reviewers* pone una aprobación manual antes de cada deploy; con eso el job se queda esperando hasta que alguien apruebe.)
3. **Variable `ALB_DNS`:** *Secrets and variables* → *Actions* → pestaña *Variables* → *New repository variable*. Nombre `ALB_DNS`, valor el DNS name **sin** `http://` (`alb-catalog-service-xxxx.us-east-1.elb.amazonaws.com`).

### 11.4 Cómo se conecta con el workflow

El workflow necesita dos cosas, que ya incluye el de la guía del pipeline (módulo 3):

- El permiso `id-token: write`, para que GitHub emita el token.
- La acción `aws-actions/configure-aws-credentials` con `role-to-assume: ${{ secrets.AWS_ROLE_ARN }}`.

Verifica la versión vigente de la acción: las versiones cambian con frecuencia.

### 11.5 Errores frecuentes

| Síntoma | Causa probable |
|---|---|
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | El `sub` no coincide: el repositorio usa el formato inmutable con IDs (creado después del 15/07/2026) y la política tiene el clásico, `USUARIO/REPO` mal escrito (mayúsculas), nombre del environment distinto, o falta uno de los dos formatos (rama o environment). Compara con el `sub` real (paso de depuración, debajo de esta tabla) |
| Error de credenciales al configurar la acción | Falta `permissions: id-token: write` en el workflow, o el secreto `AWS_ROLE_ARN` no existe |
| `AccessDenied` en una acción de ECR o ECS | Falta esa acción o ese recurso en la inline policy |
| `AccessDenied` en `iam:PassRole` | El ARN de `ecsTaskExecutionRole` en la política no coincide con el rol real |

**Ver el `sub` real que envía GitHub (depuración).** Cuando AWS rechaza el token, la forma más rápida de saber qué falta es imprimir el `sub` y compararlo, letra por letra, con la lista de la trust policy. Agrega este paso temporal en el job que falla, **antes** de la acción `configure-aws-credentials` (el job necesita `id-token: write`):

```yaml
      - name: Depuración OIDC (temporal)
        run: |
          TOKEN=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
            "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=sts.amazonaws.com" | jq -r .value)
          echo "$TOKEN" | python3 -c "import sys,base64,json; p=sys.stdin.read().split('.')[1]; p+='='*(-len(p)%4); d=json.loads(base64.urlsafe_b64decode(p)); print({k:d[k] for k in ('sub','aud','repository','ref')})"
```

Debe mostrar algo como `{'sub': 'repo:USUARIO@OWNER_ID/REPO@REPO_ID:ref:refs/heads/main', 'aud': 'sts.amazonaws.com', ...}`. Hazlo también en el job `deploy` para confirmar la forma con `environment:production`. Borra el paso cuando termines.

**Efecto de la inmutabilidad de tags en el pipeline:** con *Tag immutability* activado, volver a ejecutar (*Re-run jobs*) un workflow del mismo commit falla en el push con `ImageTagAlreadyExistsException`, porque la etiqueta con el SHA ya existe. Opciones: etiquetar con `${{ github.sha }}-${{ github.run_attempt }}`, o hacer un commit nuevo.

---

## Paso 12. Destruir todo (lección final)

> **Qué es y por qué importa**
>
> **Qué es:** borrar todo lo que creaste, en el orden inverso a sus dependencias.
>
> 1. **Evita la factura sorpresa:** ALB, Fargate y RDS cobran mientras existan, aunque nadie use la app. Es la causa principal de mala experiencia con tutoriales de AWS.
> 2. **El orden no es arbitrario:** no puedes borrar un security group que otro referencia, ni un cluster con un service activo.
> 3. **Borrar la access key** elimina la única access key que creaste en la guía.
> 4. **Revisar Billing a las 24 horas** confirma que no queda nada cobrando.

En este orden, porque hay dependencias:

```bash
aws ecs update-service --cluster catalog-service-cluster --service catalog-service --desired-count 0
aws ecs delete-service --cluster catalog-service-cluster --service catalog-service --force
aws ecs wait services-inactive --cluster catalog-service-cluster --services catalog-service
aws ecs delete-cluster --cluster catalog-service-cluster
```

Luego, en consola:

1. **ALB**
2. **Target group**
3. **RDS** (sin snapshot final)
4. **ECR** (borra el repositorio con sus imágenes)
5. **Log group**
6. **Parámetro de SSM**
7. **Security groups**: `db-catalog-service-sg`, `app-catalog-service-sg`, `alb-catalog-service-sg`, en ese orden
8. **Elimina la access key** del usuario IAM (IAM → *Users* → *Security credentials* → *Deactivate* y *Delete*). Es la única access key que se crea en toda la guía.
9. Opcional y sin costo: desregistrar las task definitions y borrar `ecsTaskExecutionRole`, el rol OIDC y el presupuesto si ya no los usas

Al final revisa *Billing → Bills* a las 24 horas para confirmar que no queda nada cobrando.

---

## Advertencias importantes

- **Costos:** ALB, Fargate, RDS e IPs públicas tienen costo mientras estén encendidos. Calcula el total con la AWS Pricing Calculator antes de empezar.
- **`AdministratorAccess`** en el paso 0 es solo para el tutorial; en un entorno real se restringe.
- **Capa gratuita:** cambió en 2025 para cuentas nuevas. Revisa qué cubre hoy antes de asumir que es gratis.
- **Solo HTTP:** esta guía expone la app por HTTP en el puerto 80, sin dominio ni HTTPS. Por eso no es una configuración de producción completa.
