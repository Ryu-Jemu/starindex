plugins {
    java
    application
}

java {
    toolchain { languageVersion.set(JavaLanguageVersion.of(21)) }
}

repositories { mavenCentral() }

dependencies {
    implementation("com.fasterxml.jackson.core:jackson-databind:2.22.3")
    testImplementation(platform("org.junit:junit-bom:6.1.3"))
    testImplementation("org.junit.jupiter:junit-jupiter")
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
}

application {
    mainClass.set("dev.starindex.catalog.CatalogBuilder")
}

val repoRoot = rootProject.projectDir.parentFile

tasks.named<JavaExec>("run") {
    workingDir = repoRoot
}

tasks.test {
    useJUnitPlatform()
    systemProperty("repoRoot", repoRoot.absolutePath)
}
