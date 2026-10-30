# Requisitos Previos

Para el desarrollo, pruebas locales y la correcta ejecución del pipeline de integración y despliegue continuo (CI/CD), es necesario contar con las siguientes herramientas y configuraciones previas:

### 1. Entorno de Desarrollo y Lenguaje
* **[Java JDK 21](https://docs.aws.amazon.com/es_es/corretto/latest/corretto-21-ug/downloads-list.html):** Kit de desarrollo de Java (Amazon Corretto 21 recomendado). Asegúrate de que la variable de entorno `JAVA_HOME` esté correctamente configurada.
* **[IntelliJ IDEA](https://www.jetbrains.com/idea/download/?section=windows):** Entorno de desarrollo integrado (IDE) para Java y Spring Boot.
* **[Apache Maven](https://maven.apache.org/download.cgi):** Gestor de dependencias y construcción. Debe estar descargado y configurado en las variables de entorno del sistema (`PATH`).

### 2. Control de Versiones y Repositorios
* **[Git](https://git-scm.com/):** Sistema de control de versiones para el código fuente.
* **[Cuenta en GitHub](https://github.com/):** Necesaria para alojar el repositorio y configurar los workflows de GitHub Actions.

### 3. Contenedores e Infraestructura Local
* **Docker Desktop:** Utilizado para la contenerización de servicios y pruebas de imágenes locales.
  > **Nota de instalación en Windows:**
  > 1. Abre PowerShell como Administrador e instala WSL ejecutando: `wsl --install`
  > 2. Reinicia tu computadora.
  > 3. Descarga e instala [Docker Desktop](https://docs.docker.com/desktop/setup/install/windows-install/).
* **[MySQL Server 8.0.46](https://dev.mysql.com/downloads/windows/installer/8.0.html):** Base de datos relacional para el almacenamiento local del dominio.
* **[DBeaver](https://dbeaver.io/):** Cliente de base de datos universal para la gestión y consulta de MySQL.

### 4. Pruebas y Seguridad
* **[Postman](https://www.postman.com/downloads/):** Herramienta para probar y documentar los endpoints de la API REST.
* **Microsoft Authenticator:** Aplicación móvil (disponible en Play Store / App Store) requerida para la verificación en dos pasos (2FA) en las cuentas de GitHub y accesos corporativos/cloud.

### 5. Configuración de la Interfaz CLI (Referencia)
* **Configuración de la Interfaz de Línea de Comandos:** No te preocupes si aún no la tienes configurada; esta sección y su ajuste detallado se realizarán paso a paso de manera directa durante el desarrollo del curso, por lo que puedes tomarlo como una referencia inicial.