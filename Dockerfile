# ---------- Build ----------
FROM eclipse-temurin:21-jdk AS build
WORKDIR /workspace

COPY .mvn/ .mvn/
COPY mvnw pom.xml ./
RUN ./mvnw -q dependency:go-offline

COPY src ./src
RUN ./mvnw -q package -DskipTests

# Extrae el jar en capas (dependencias / loader / app)
RUN cp target/*.jar app.jar && \
    java -Djarmode=tools -jar app.jar extract --layers --destination extracted

# ---------- Runtime ----------
FROM eclipse-temurin:21-jre
RUN useradd -r -u 1001 spring
WORKDIR /app

# De menos a más cambiante, para aprovechar la caché de capas
COPY --from=build /workspace/extracted/dependencies/ ./
COPY --from=build /workspace/extracted/spring-boot-loader/ ./
COPY --from=build /workspace/extracted/snapshot-dependencies/ ./
COPY --from=build /workspace/extracted/application/ ./

USER 1001
EXPOSE 8080
ENTRYPOINT ["java", "-XX:MaxRAMPercentage=75", "-jar", "app.jar"]