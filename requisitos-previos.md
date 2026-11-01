# Requisitos Previos

Para el desarrollo, pruebas locales y la correcta ejecución del pipeline de integración y despliegue continuo (CI/CD), es necesario contar con las siguientes herramientas y configuraciones previas:

### 1. Entorno de Desarrollo y Lenguaje
* **[Java JDK 21](https://docs.aws.amazon.com/es_es/corretto/latest/corretto-21-ug/downloads-list.html):** Kit de desarrollo de Java (Amazon Corretto 21 recomendado). Asegúrate de que la variable de entorno `JAVA_HOME` esté correctamente configurada.
* **[IntelliJ IDEA](https://www.jetbrains.com/idea/download/?section=windows):** Entorno de desarrollo integrado (IDE) para Java y Spring Boot.
* **[Apache Maven](https://maven.apache.org/download.cgi):** Gestor de dependencias y construcción. Debe estar descargado y configurado en las variables de entorno del sistema (`PATH`).

### 2. Control de Versiones y Repositorios
* **[Git](https://git-scm.com/):** Sistema de control de versiones para el código fuente.
* **[Cuenta en GitHub](https://github.com/):** Necesaria para alojar el reposito rio y configurar los workflows de GitHub Actions.
* **[GitHub CLI (`gh`)](https://cli.github.com/):** se usa en el módulo 3 para o btener los IDs de tu repositorio al configurar el acceso de GitHub a AWS. Puedes instalarlo cuando llegues a ese punto.

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
* **App de autenticación (por ejemplo, Microsoft Authenticator o Google Authenticator):** aplicación móvil para activar la verificación en dos pasos (MFA) en tu cuenta de AWS (módulo 2) y en GitHub.

### 5. AWS CLI (se configura durante el curso)
* **[AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html):** no te preocupes si aún no la tienes. Se instala y configura paso a paso en el módulo 2, junto con la cuenta de AWS.