FROM gradle:8.14.3-jdk17 AS build
WORKDIR /app
COPY . .
RUN gradle clean bootJar -x test

FROM eclipse-temurin:17-jre
WORKDIR /app
COPY --from=build /app/build/libs/*.jar app.jar
EXPOSE 8081
ENTRYPOINT ["java", "-jar", "app.jar"]