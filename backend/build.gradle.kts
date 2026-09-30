plugins {
    java
    id("org.springframework.boot") version "4.1.1"
    id("io.spring.dependency-management") version "1.1.7"
}

group = "dev.starindex"
version = "0.1.0"

java {
    toolchain { languageVersion.set(JavaLanguageVersion.of(21)) }
}

repositories { mavenCentral() }

val querydslVersion = "7.7"   // OpenFeign fork (ADR-004); 7.6 is the fallback if 7.7 misbehaves

dependencies {
    implementation("org.springframework.boot:spring-boot-starter-webmvc")
    implementation("org.springframework.boot:spring-boot-starter-websocket")
    implementation("org.springframework.boot:spring-boot-starter-batch-jdbc")
    implementation("org.springframework.boot:spring-boot-starter-data-jpa")
    implementation("org.springframework.boot:spring-boot-starter-flyway")
    implementation("org.flywaydb:flyway-database-postgresql")   // Flyway 10+: PostgreSQL support lives in this module
    implementation("org.springframework.boot:spring-boot-starter-data-redis")
    implementation("org.springframework.boot:spring-boot-starter-actuator")

    implementation("io.github.openfeign.querydsl:querydsl-jpa:$querydslVersion")
    annotationProcessor("io.github.openfeign.querydsl:querydsl-apt:$querydslVersion:jpa")
    annotationProcessor("jakarta.persistence:jakarta.persistence-api")

    // Astronomy Engine v2.1.19 (MIT), same release as the iOS C sources (commit 61dc070).
    implementation(files("libs/astronomy-2.1.19.jar"))
    implementation("org.jetbrains.kotlin:kotlin-stdlib")

    runtimeOnly("org.postgresql:postgresql")

    testImplementation("org.springframework.boot:spring-boot-starter-test")
    testImplementation("org.springframework.boot:spring-boot-starter-batch-jdbc-test")
    testImplementation("org.springframework.boot:spring-boot-testcontainers")
    testImplementation("org.testcontainers:testcontainers-postgresql")
    // Pinned: Maven Central's "latest" is a 4.0.0 beta. Standalone jar shades Jetty (no clash with Boot's Jetty BOM).
    testImplementation("org.wiremock:wiremock-standalone:3.13.2")
    testImplementation("org.testcontainers:testcontainers-junit-jupiter")
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
}

tasks.test {
    useJUnitPlatform()
}
