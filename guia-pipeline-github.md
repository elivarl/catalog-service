# Guía paso a paso: Módulo 3. Pipeline completo (GitHub Actions → ECR → ECS)

Módulo 3 del tutorial *Spring Boot de local a producción: CI/CD con GitHub Actions y AWS*. Continúa la guía de consola (ECR + ECS Fargate + ALB): los pasos 0 a 10 dejaron lista la infraestructura (módulo 2) y el paso 11 creó el rol OIDC, al inicio de este módulo.

**Tiempos:** estimados de ejecución en vivo.

| Bloque | Min |
|---|---|
| 3.0 Verificación previa  | 4 |
| 3.1 Workflow base + job `test` | 6 |
| 3.2 Job `build-and-push` | 8 |
| 3.3 Job `deploy` | 8 |
| 3.4 Primer despliegue y verificación | 5 |
| 3.5 Segundo despliegue (cambio visible) | 4 |
| **Total** | **35** |

3.6 (romper a propósito) es contenido extra y no cuenta en los 35 minutos.

---

## Qué vas a construir

```
git push a main
   │
   ▼
[test]  ──▶  [build-and-push]  ──▶  [deploy]
 mvn verify    imagen :<SHA> a ECR    nueva task definition
 (con MySQL)   (rol OIDC, rama main)  + update del service + espera
                                      (rol OIDC, environment production)
                                      + smoke test al ALB
```

En un Pull Request corre **solo `test`**. Build y deploy corren únicamente en push a `main`.

## Nombres usados (los mismos de la guía de consola)

| Variable del workflow | Valor | Viene de |
|---|---|---|
| `AWS_REGION` | `us-east-1` | Paso 0 |
| `ECR_REPOSITORY` | `catalog-service` | Paso 1 |
| `ECS_CLUSTER` | `catalog-service-cluster` | Paso 7 |
| `ECS_SERVICE` | `catalog-service` | Paso 9 |
| `CONTAINER_NAME` | `app` | Paso 8.2 (`name` del contenedor) |
| `TASK_DEFINITION` | `.aws/task-definition.json` | Paso 8.2 |
| Secreto `AWS_ROLE_ARN` | ARN de `github-actions-catalog-service` | Paso 11.3 |
| Environment | `production` | Paso 11.2b (trust policy) |
| Variable `ALB_DNS` | DNS name de `alb-catalog-service` | Paso 6.2 (la variable se crea en el paso 11.3) |

Si nombraste distinto algún recurso, cambia el valor aquí y en el workflow. La tabla de la guía de consola (*Nota: si usas nombres distintos*) sigue vigente.

## Decisiones que toma esta guía

| Decisión | Qué se hace | Por qué |
|---|---|---|
| Etiqueta de la imagen | `${{ github.sha }}` | Con *Tag immutability* activo, cada commit tiene su imagen única y el rollback apunta a un commit exacto. Resuelve la decisión que quedó abierta al final del paso 11 |
| Build y deploy en jobs separados | Dos jobs, dos permisos OIDC | Coincide con los dos formatos de `sub` de la trust policy del paso 11.2b: `build-and-push` (sin environment) entra por `ref:refs/heads/main`; `deploy` (con `environment: production`) entra por `environment:production` |
| Tests con MySQL real | Contenedor de servicio `mysql:8.4` en el job `test` | La app exige `SPRING_DATASOURCE_*` al arrancar. Usa las mismas variables que en Docker local |
| Sin caché de capas ni de Maven | Fuera del alcance de este curso | Cada build en CI descarga todas las dependencias. Es más lento, pero el workflow queda más simple de entender |
| Smoke test al final | `curl` al ALB tras el deploy | Confirma desde fuera que la versión nueva responde, no solo que ECS dice "estable" |

---

## Paso 3.0. Verificación previa (4 min)

> **Qué es y por qué importa**
>
> **Qué es:** confirmar que el punto de partida funciona a mano antes de automatizar.
>
> 1. **Si falla el pipeline, sabrás de quién es la culpa:** si el paso 10 de la guía de consola da `healthy` y responde, un fallo posterior es del pipeline, no de la infraestructura.
> 2. **El pipeline no crea nada:** solo reemplaza la imagen de un service que ya existe. Si el service o el rol no existen, el pipeline falla sin importar cómo lo escribas.

Desde tu máquina, con `aws configure` ya hecho:

```bash
# 1) El service existe y corre 1 tarea con la revisión 1
aws ecs describe-services --cluster catalog-service-cluster --services catalog-service \
  --query 'services[0].{estado:status,corriendo:runningCount,taskDef:taskDefinition}'

# 2) La app responde por el ALB
curl http://<ALB_DNS>/actuator/health      # {"status":"UP"}

# 3) El rol OIDC existe
aws iam get-role --role-name github-actions-catalog-service --query 'Role.Arn' --output text

# 4) La trust policy tiene el sub real de tu repositorio (ver 11.2b de la guía de consola)
aws iam get-role --role-name github-actions-catalog-service --query "Role.AssumeRolePolicyDocument.Statement[0].Condition.StringLike" --output json
gh api repos/USUARIO/REPO --jq "{repo_id: .id, owner_id: .owner.id}"
```

Debes ver `ACTIVE`, `1` tarea corriendo, `taskDef` terminando en `catalog-service:1`, `UP` y el ARN del rol. En el punto 4, la lista de `sub` debe contener `repo:USUARIO@OWNER_ID/REPO@REPO_ID:ref:refs/heads/main` y `repo:USUARIO@OWNER_ID/REPO@REPO_ID:environment:production`, con los IDs que imprime `gh api` y tu usuario y repositorio escritos igual, letra por letra. Si tu repositorio es anterior al 15 de julio de 2026, usa el formato clásico y va sin los `@ID`. Si algo falla, vuelve al paso 10 u 11 de la guía de consola.

**Archivos del repositorio.** Comprueba que estos tres están **subidos a `main` en GitHub**. Un `git ls-files` solo mira tu copia local; lo que cuenta es lo que el runner descarga:

```bash
git fetch origin
git ls-tree -r origin/main --name-only -- Dockerfile mvnw .aws/task-definition.json
```

Los tres deben aparecer, con esos nombres exactos. Linux distingue mayúsculas y el punto inicial es parte del nombre: una carpeta `aws` en lugar de `.aws` hace que el job `deploy` falle con `Task definition file does not exist`. Si falta alguno, haz `git add`, commit y push a `main` antes de seguir. Dos trampas conocidas:

- Si trabajas desde Windows, el Maven wrapper pierde el permiso de ejecución y el runner Linux falla con `Permission denied`. Arréglalo una sola vez:
  ```bash
  git update-index --chmod=+x mvnw
  git commit -m "mvnw ejecutable"
  ```
- El `.aws/task-definition.json` debe tener tus valores reales (sin `<ACCOUNT_ID>` ni `<RDS_ENDPOINT>`). Compruébalo con `grep -n "<" .aws/task-definition.json`: no debe imprimir nada.

---

## Paso 3.1. Workflow base y job `test` (6 min)

> **Qué es y por qué importa**
>
> **Qué es:** el archivo `.github/workflows/ci-cd.yml`, con los disparadores, los permisos y el primer job: compilar y ejecutar las pruebas.
>
> 1. **`pull_request` + `push` a `main`:** el PR valida; el push a `main` además despliega (los otros jobs, más adelante).
> 2. **`permissions: contents: read` arriba:** mínimo privilegio por defecto. Los jobs que necesiten OIDC lo amplían con `id-token: write`.
> 3. **Contenedor de servicio MySQL:** el job levanta un MySQL descartable junto a las pruebas, con las mismas variables de entorno que en local y en ECS. Es la misma idea, con otro valor.
> 4. **Credenciales del CI:** son de un MySQL que existe solo durante el job; por eso van en el archivo y no son secretos reales.

Crea `.github/workflows/ci-cd.yml` en la raíz del proyecto:

```yaml
name: CI/CD

on:
  pull_request:
    branches: [main]
  push:
    branches: [main]

permissions:
  contents: read

env:
  AWS_REGION: us-east-1
  ECR_REPOSITORY: catalog-service
  ECS_CLUSTER: catalog-service-cluster
  ECS_SERVICE: catalog-service
  CONTAINER_NAME: app
  TASK_DEFINITION: .aws/task-definition.json

jobs:
  test:
    runs-on: ubuntu-latest
    services:
      mysql:
        image: mysql:8.4
        env:
          MYSQL_ROOT_PASSWORD: ci-root-pass
          MYSQL_DATABASE: products
          MYSQL_USER: app
          MYSQL_PASSWORD: ci-app-pass
        ports:
          - 3306:3306
        options: >-
          --health-cmd="mysqladmin ping -h 127.0.0.1 -uroot -pci-root-pass --silent"
          --health-interval=5s
          --health-timeout=5s
          --health-retries=20
    env:
      SPRING_DATASOURCE_URL: jdbc:mysql://localhost:3306/products?allowPublicKeyRetrieval=true&useSSL=false
      SPRING_DATASOURCE_USERNAME: app
      SPRING_DATASOURCE_PASSWORD: ci-app-pass
    steps:
      - uses: actions/checkout@v6

      - uses: actions/setup-java@v5
        with:
          distribution: temurin
          java-version: '21'

      - name: Pruebas
        run: ./mvnw -B verify
```

Notas:

- El job corre en el runner, no en un contenedor, por eso el host de MySQL es `localhost` (el puerto `3306` está publicado). Dentro de Docker local era el nombre del contenedor; aquí no.
- Si tus pruebas **no** usan base de datos (por ejemplo, usan H2 o Testcontainers), borra el bloque `services` y las tres variables `SPRING_DATASOURCE_*`.
- `java-version: '21'` coincide con el Temurin 21 del Dockerfile.

**Ejecuta y verifica:**

```bash
git checkout -b feature/pipeline
git add .github/workflows/ci-cd.yml
git commit -m "Pipeline: job test"
git push -u origin feature/pipeline
```

Abre un Pull Request hacia `main`. En la pestaña *Actions* debe correr `CI/CD` con **solo** el job `test`, en verde. No hace falta fusionar todavía: sigue en la misma rama con los pasos 3.2 y 3.3.

---

## Paso 3.2. Job `build-and-push` (8 min)

> **Qué es y por qué importa**
>
> **Qué es:** el job que construye la imagen Docker y la sube a ECR con el SHA del commit como etiqueta.
>
> 1. **`needs: test`:** si las pruebas fallan, no se construye ni se sube nada.
> 2. **`if: github.event_name == 'push'`:** en un PR no se toca AWS. Además, un PR tendría otro `sub` y la trust policy lo rechazaría.
> 3. **Sin `environment`:** así el token trae el `sub` de la rama `main` (termina en `:ref:refs/heads/main`), el primero de los dos que acepta la trust policy.
> 4. **`permissions: id-token: write`:** sin esto GitHub no emite el token y falla la autenticación. Al declarar `permissions` en el job, reemplaza el bloque de arriba del archivo, por eso se repite `contents: read`.
> 5. **Salida `image`:** el job publica la URI completa de la imagen para que `deploy` use exactamente esa, sin recalcularla.
> 6. **`platforms: linux/amd64`:** la task definition es `X86_64`. El runner ya es x86_64; declararlo evita el `exec format error` si alguien cambia de runner.
> 7. **`provenance: false`:** hasta donde sé, desde la v4 de `build-push-action` se agrega por defecto una atestación de procedencia que añade un manifiesto extra a la imagen en ECR. Se desactiva para mantener una sola entrada limpia en el repositorio. Verifícalo en tu ECR.

Agrega este job debajo de `test`, dentro de `jobs:` (misma indentación que `test`):

```yaml
  build-and-push:
    needs: test
    if: github.event_name == 'push'
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write
    outputs:
      image: ${{ steps.meta.outputs.image }}
    steps:
      - uses: actions/checkout@v6

      - name: Credenciales de AWS (OIDC)
        uses: aws-actions/configure-aws-credentials@v6
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
          aws-region: ${{ env.AWS_REGION }}

      - name: Login en ECR
        id: login-ecr
        uses: aws-actions/amazon-ecr-login@v2

      - name: URI de la imagen
        id: meta
        run: echo "image=${{ steps.login-ecr.outputs.registry }}/${{ env.ECR_REPOSITORY }}:${{ github.sha }}" >> "$GITHUB_OUTPUT"

      - uses: docker/setup-buildx-action@v4

      - name: Build y push
        uses: docker/build-push-action@v7
        with:
          context: .
          platforms: linux/amd64
          push: true
          tags: ${{ steps.meta.outputs.image }}
          provenance: false
```

**Ejecuta y verifica.** Para probar este job ahora sin esperar al deploy, fusiona el PR a `main` (el push a `main` dispara `test` y `build-and-push`; `deploy` aún no existe):

1. *Actions*: `test` y `build-and-push` en verde. Anota cuánto tardó el build: sin caché, cada build descarga todas las dependencias.
2. ECR → `catalog-service` → *Images*: aparece una imagen con una etiqueta de 40 caracteres.
3. Esa etiqueta debe ser el SHA del commit:
   ```bash
   git rev-parse HEAD
   ```
4. El service **no cambió**: sigue en `catalog-service:1`. Es lo esperado.

Luego crea la rama para el siguiente paso: `git checkout main && git pull && git checkout -b feature/deploy`.

---

## Paso 3.3. Job `deploy` (8 min)

> **Qué es y por qué importa**
>
> **Qué es:** el job que toma la imagen ya subida, la inyecta en la task definition del repositorio, registra una revisión nueva, actualiza el service y espera a que quede estable.
>
> 1. **`environment: production`:** es el segundo formato de `sub` de la trust policy. También es el punto donde luego se pueden agregar aprobaciones o secretos propios del entorno.
> 2. **`checkout` otra vez:** cada job corre en una máquina limpia. Este necesita el archivo `.aws/task-definition.json`.
> 3. **Render + deploy:** *render* cambia solo el campo `image` del contenedor `app` y deja todo lo demás igual; *deploy* registra la revisión (`catalog-service:2`, `catalog-service:3`, ...) y apunta el service a ella.
> 4. **`wait-for-service-stability`:** sin esto el job termina en verde en cuanto ECS acepta el cambio, aunque la tarea nueva muera dos minutos después. Con la espera, el job falla si el despliegue no se estabiliza (por ejemplo, si el circuit breaker del paso 9 revierte).
> 5. **`concurrency`:** dos deploys simultáneos pelearían por el mismo service. Con `cancel-in-progress: false`, el segundo espera al primero.
> 6. **Smoke test:** el `curl` al ALB comprueba desde internet que la versión nueva responde. Reintenta porque el ALB tarda unos segundos en registrar el target sano.

Agrega este job debajo de `build-and-push`:

```yaml
  deploy:
    needs: build-and-push
    runs-on: ubuntu-latest
    environment: production
    concurrency:
      group: deploy-production
      cancel-in-progress: false
    permissions:
      contents: read
      id-token: write
    steps:
      - uses: actions/checkout@v6

      - name: Credenciales de AWS (OIDC)
        uses: aws-actions/configure-aws-credentials@v6
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
          aws-region: ${{ env.AWS_REGION }}

      - name: Inyectar la imagen en la task definition
        id: render
        uses: aws-actions/amazon-ecs-render-task-definition@v1
        with:
          task-definition: ${{ env.TASK_DEFINITION }}
          container-name: ${{ env.CONTAINER_NAME }}
          image: ${{ needs.build-and-push.outputs.image }}

      - name: Desplegar en ECS
        uses: aws-actions/amazon-ecs-deploy-task-definition@v2
        with:
          task-definition: ${{ steps.render.outputs.task-definition }}
          service: ${{ env.ECS_SERVICE }}
          cluster: ${{ env.ECS_CLUSTER }}
          wait-for-service-stability: true
          wait-for-minutes: 10

      - name: Smoke test
        run: |
          for i in $(seq 1 12); do
            if curl -fsS -m 5 "http://${{ vars.ALB_DNS }}/actuator/health" | grep -q '"status":"UP"'; then
              echo "App arriba"
              exit 0
            fi
            echo "Intento $i: aún no responde"
            sleep 10
          done
          exit 1
```

El archivo final es, en orden: el encabezado del paso 3.1 (`name`, `on`, `permissions`, `env`), y bajo `jobs:` los tres jobs `test`, `build-and-push` y `deploy`.

---

## Paso 3.4. Primer despliegue y verificación (5 min)

Sube la rama, abre el PR y fusiona a `main`:

```bash
git add .github/workflows/ci-cd.yml
git commit -m "Pipeline: job deploy"
git push -u origin feature/deploy
```

El PR corre solo `test`. Al fusionar, el push a `main` corre los tres jobs. El deploy tarda unos minutos porque ECS arranca la tarea nueva, espera al health check y drena la anterior.

**Verifica en orden (cada capa falla distinto):**

1. **GitHub → Actions:** `test` → `build-and-push` → `deploy`, los tres en verde. En `deploy`, el paso *Desplegar en ECS* muestra la revisión registrada y espera la estabilidad.
2. **ECS → Task definitions → `catalog-service`:** hay una revisión nueva (`catalog-service:2` o la siguiente) y su `image` termina en el SHA del commit.
3. **Service y despliegue:**
   ```bash
   aws ecs describe-services --cluster catalog-service-cluster --services catalog-service \
     --query 'services[0].deployments[].{estado:rolloutState,taskDef:taskDefinition,corriendo:runningCount}'
   ```
   Debe quedar un solo despliegue con `COMPLETED`, apuntando a la revisión nueva.
4. **La imagen que corre es la del commit:**
   ```bash
   aws ecs describe-task-definition --task-definition catalog-service \
     --query 'taskDefinition.containerDefinitions[0].image' --output text
   git rev-parse HEAD
   ```
   La etiqueta de la imagen coincide con el SHA.
5. **Target group:** EC2 → `tg-catalog-service` → *Targets*: healthy.
6. **Desde fuera:** `curl http://<ALB_DNS>/actuator/health` → `{"status":"UP"}`.

---

## Paso 3.5. Segundo despliegue: un cambio visible (4 min)

Es la escena central del módulo: `git push` y la nueva versión aparece sin tocar la consola.

1. Haz un cambio observable en la API (por ejemplo, un campo nuevo en la respuesta de `/api/v1/products` o un mensaje distinto) y comprueba que las pruebas siguen pasando.
2. Commit y push directo a `main` (o por PR, si quieres mostrar el flujo completo).
3. Mira *Actions*: los tres jobs corren de nuevo.
4. Cuando termine, `curl http://<ALB_DNS>/api/v1/products` muestra el cambio.
5. ECS → Task definitions: ahora hay una revisión más, con el SHA nuevo. ECR: dos imágenes de la app más la `v1` manual.

---

## Paso 3.6. Romper a propósito (extra)

Son errores que puedes encontrar al trabajar con este pipeline. Cada uno se prueba en una rama o commit y se revierte.

| Qué rompes | Qué se ve | Qué enseña |
|---|---|---|
| Una prueba que falle (`assertEquals(1, 2)`) | `test` en rojo; `build-and-push` y `deploy` no corren; ECR sin imagen nueva | El pipeline protege producción: nada llega a AWS si las pruebas fallan |
| Cambiar `environment: production` por `prod` en el job `deploy` | `Not authorized to perform sts:AssumeRoleWithWebIdentity` | La trust policy compara el `sub`; el nombre del environment es parte de la seguridad |
| *Re-run all jobs* sobre un commit ya desplegado | `ImageTagAlreadyExistsException` en el push | La inmutabilidad de tags funciona. Solución: un commit nuevo, o *Re-run failed jobs*, que repite solo el job fallido y reutiliza la imagen ya subida |
| Un `CONTAINER_NAME` distinto de `app` | El render falla al no encontrar el contenedor | El nombre del contenedor es el vínculo entre el workflow y la task definition |

Un despliegue que arranca pero queda `unhealthy` y activa el rollback automático queda fuera del alcance de este curso. Si te ocurre, es el circuit breaker que activaste en el paso 9 de la guía de consola el que vuelve a la versión anterior.

---

## Errores frecuentes

| Síntoma | Causa probable |
|---|---|
| `mvnw: Permission denied` | El wrapper perdió el bit de ejecución (Windows). `git update-index --chmod=+x mvnw` y commit |
| `Could not resolve placeholder 'SPRING_DATASOURCE_URL'` en `test` | Faltan las variables `SPRING_DATASOURCE_*` en el job, o están fuera del bloque `env` del job |
| `Communications link failure` en `test` | El host debe ser `localhost` (no el nombre del servicio), o MySQL aún no estaba listo: revisa el `health-cmd` |
| `Credentials could not be loaded` / error al configurar la acción | Falta `id-token: write` en el **job** (el `permissions` del job reemplaza al del archivo), o el secreto `AWS_ROLE_ARN` no existe |
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | Repositorio creado después del 15/07/2026 con la política en formato clásico (el `sub` real lleva `@OWNER_ID` y `@REPO_ID`), `USUARIO/REPO` con mayúsculas distintas, nombre del environment distinto, o falta uno de los dos formatos (rama o environment). Imprime el `sub` real con el paso de depuración de 11.5 y compáralo con la trust policy |
| `no basic auth credentials` al hacer push | Falta el paso `amazon-ecr-login` antes del build, o el rol no tiene `ecr:GetAuthorizationToken` |
| `ImageTagAlreadyExistsException` | Re-ejecución de un commit ya publicado. Usa un commit nuevo o *Re-run failed jobs* |
| `AccessDenied` en una acción de ECR o ECS | Falta esa acción o recurso en la inline policy `desplegar-catalog-service`. El mensaje nombra la acción y el recurso exactos: agrégalos |
| `not authorized to perform: ecr:BatchGetImage` al hacer el push | Falta esa acción en la inline policy `desplegar-catalog-service` (lista de 11.2c). Agrégala sobre el repositorio `catalog-service` |
| `AccessDenied` en `iam:PassRole` | El ARN de `ecsTaskExecutionRole` en la política no coincide con el rol real |
| `Task definition file does not exist: .aws/task-definition.json` en `deploy` | La carpeta se llama `aws` sin punto, el archivo no está en `main`, o falta `actions/checkout` en el job `deploy`. Comprueba con `git ls-tree -r origin/main --name-only -- .aws/task-definition.json` |
| El render no encuentra el contenedor | `CONTAINER_NAME` distinto del `name` en `.aws/task-definition.json` |
| Error de service o cluster no encontrado | `ECS_SERVICE` o `ECS_CLUSTER` no coinciden con lo creado en los pasos 7 y 9 |
| `Waiter has timed out` (`"state":"TIMEOUT"`) o error de estabilidad en el paso de deploy | El service no se estabilizó dentro de `wait-for-minutes`. Mira *Events* del service, los *Stopped reason* y `aws logs tail /ecs/catalog-service`; es el mismo diagnóstico del paso 10 de la guía de consola. Si ECS ya muestra el despliegue como *Complete*, solo va lento: sube `wait-for-minutes` |
| `Target is in an Availability Zone that is not enabled for the load balancer` en *Events* del service | El service tiene subredes en zonas donde el ALB no está, y ECS puso la tarea en una de ellas. La tarea falla el health check y ECS la reemplaza, lo que alarga el despliegue. Deja en el service solo las subredes del ALB (paso 9 de la guía de consola) |
| El smoke test falla pero el deploy terminó bien | `ALB_DNS` mal escrito o con `http://`; o el ALB aún no marcaba el target como sano |

---

## Notas finales

- **Versiones de las acciones.** Las usadas en esta guía, comprobadas el 16 de octubre de 2026: `actions/checkout@v6`, `actions/setup-java@v5`, `docker/setup-buildx-action@v4`, `docker/build-push-action@v7`, `aws-actions/configure-aws-credentials@v6`, `aws-actions/amazon-ecr-login@v2`, `aws-actions/amazon-ecs-render-task-definition@v1` y `aws-actions/amazon-ecs-deploy-task-definition@v2`. Verifica las versiones vigentes antes de ejecutar el workflow.
- **Si tus pruebas no usan base de datos,** quita el contenedor de servicio de MySQL del job `test` para simplificarlo.
- **Costos:** el service sigue encendido entre ejecuciones. Recuerda el paso 12 (destruir todo) al terminar.

## Anexo: ¿para qué sirve cada `uses:` del pipeline?

En términos sencillos, cada **`uses:`** es como importar una **librería o un bloque de código prefabricado**. En lugar de tener que escribir cientos de líneas de comando manuales en la terminal para conectarte a AWS o configurar Docker, alguien más (GitHub, Docker o AWS) ya hizo ese trabajo pesado por ti, lo empaquetó y te lo comparte para que lo ejecutes con una sola línea.

A continuación se detalla la función, el objetivo y las consideraciones de cambio para cada una de las acciones declaradas en el flujo:

---

### 1. `actions/checkout@v6`

* **¿Para qué sirve?:** Descarga el código fuente de tu repositorio dentro del servidor temporal de GitHub.
* **El objetivo:** Los servidores donde corre tu pipeline arrancan 100% vacíos. Este paso equivale a hacer un `git clone` automático de tu proyecto para que las herramientas del flujo puedan leer tu `Dockerfile`, tus carpetas de código y tus archivos de configuración.
* **Consideraciones para cambiarlo:** Cámbialo solo cuando GitHub lance una nueva versión mayor (como una `@v7` o `@v8`) que optimice la velocidad de descarga o solucione problemas de seguridad en sistemas operativos de servidores nuevos.

---

### 2. `actions/setup-java@v5`

* **¿Para qué sirve?:** Instala y configura el entorno de desarrollo de Java (JDK).
* **El objetivo:** Como el servidor está completamente limpio al iniciar, no reconoce comandos de Java. Esta herramienta descarga e instala la versión exacta que le pidas (en tu caso, Java 21 de Temurin) para que el comando `./mvnw` pueda compilar y probar tu aplicación con éxito.
* **Consideraciones para cambiarlo:** Revisa su repositorio si decides cambiar la versión de Java de tu proyecto (por ejemplo, si en el futuro migras tu app a Java 25 o 27) para asegurarte de que esa versión de la Action soporte los nuevos JDKs.

---

### 3. `aws-actions/configure-aws-credentials@v6`

* **¿Para qué sirve?:** Conecta de forma segura tu pipeline con tu cuenta de AWS mediante el protocolo OIDC (OpenID Connect).
* **El objetivo:** Le otorga permisos temporales al servidor de GitHub para interactuar con tus servicios de AWS sin necesidad de guardar contraseñas fijas ni credenciales peligrosas en tu código de forma permanente. Genera llaves de acceso dinámicas que caducan en cuanto el pipeline termina.
* **Consideraciones para cambiarlo:** **Mucha atención aquí.** Amazon actualiza esta herramienta frecuentemente por razones de seguridad cibernética. Si AWS anuncia que las versiones viejas sufren vulnerabilidades o cambian la forma en que se conectan con GitHub, es obligatorio subir a la versión más reciente para que no se bloqueen tus despliegues.

---

### 4. `aws-actions/amazon-ecr-login@v2`

* **¿Para qué sirve?:** Autentica las herramientas de Docker dentro del registro privado de imágenes de AWS (Amazon ECR).
* **El objetivo:** Permite que tu pipeline obtenga los permisos necesarios para poder subir (hacer `push`) la imagen de Docker empaquetada hacia el almacén de AWS.
* **Consideraciones para cambiarlo:** Cámbialo si cambia la API de Amazon ECR o si Docker actualiza sus protocolos de autenticación de seguridad globales.

---

### 5. `docker/setup-buildx-action@v4` y `docker/build-push-action@v7`

* **¿Para qué sirven?:** Configuran el motor avanzado de Docker (Buildx) y empaquetan tu aplicación en una imagen para luego subirla a AWS ECR.
* **El objetivo:** Ejecutan el proceso automatizado de leer tu `Dockerfile`, empaquetar tu código compilado de Java y subir el contenedor empaquetado a la nube de AWS.
* **Consideraciones para cambiarlo:** Estas herramientas avanzan muy rápido. Cámbialas si necesitas compilar imágenes para diferentes arquitecturas de procesador (como compilar en servidores Intel para que corran en chips ARM de AWS Graviton) o si quieres optimizar el tamaño y la velocidad del empaquetado.

---

### 6. `aws-actions/amazon-ecs-render-task-definition@v1` y `amazon-ecs-deploy-task-definition@v2`

* **¿Para qué sirven?:** Actualizan la configuración de tu contenedor en AWS (Task Definition) y le avisan a AWS ECS que apunte a la nueva versión que acabas de subir.
* **El objetivo:** Realizan el despliegue final en producción. Toman el archivo `.aws/task-definition.json`, le inyectan la nueva etiqueta única de la imagen (`github.sha`) y le ordenan a AWS ECS que reinicie los servidores con el código nuevo de forma progresiva (despliegue *Rolling Update*) para que la app no deje de funcionar ni un solo segundo.
* **Consideraciones para cambiarlo:** Revísalas si cambias la forma en que ejecutas tus servicios en ECS (por ejemplo, si pasas de Fargate a instancias EC2).

---

### 💡 Resumen de consideraciones generales para cambiarlos

1. **Mantén la versión mayor (`@vX`):** Deja que GitHub maneje los parches menores. Si usas `@v6`, recibirás mejoras automáticas de rendimiento sin que se rompa la compatibilidad de tus comandos.
2. **Si no está roto, no lo toques... salvo por seguridad:** Para tu primer despliegue, las versiones actuales de tu archivo son perfectas. Solo planifica actualizarlas cada 6 meses o un año para evitar que queden obsoletas (*deprecated*).
3. **La prueba del error:** Recuerda que si pones una versión incorrecta o inexistente, GitHub Actions detendrá el proceso de inmediato y te dirá exactamente qué línea falló en la pestaña de monitoreo.
