# Reiner Wegwerf-Builder: erzeugt nur das JAR, damit auf dem Host kein
# Java/Maven installiert sein muss. Keine Keycloak-Stage - das Einhaengen des
# JARs in die bestehende Instanz passiert per Volume-Mount (siehe README.md).
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /app
COPY pom.xml .
COPY src/ src/
RUN mvn -B clean package

FROM scratch AS export
COPY --from=build /app/target/requested-tenant-mapper.jar /
