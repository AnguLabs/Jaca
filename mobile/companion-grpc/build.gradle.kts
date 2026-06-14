import com.google.protobuf.gradle.id

// Plain JVM library holding the generated protobuf + gRPC stubs for the companion
// link. Deliberately NOT an Android module: protobuf-gradle-plugin has no real KMP
// support and AGP 9 changed KMP/Android integration, so a java-library keeps the
// codegen on its rock-solid, best-supported path. The KMP composeApp android target
// depends on this; the generated (lite) stubs run fine on ART.

plugins {
    `java-library`
    alias(libs.plugins.protobuf)
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

sourceSets {
    main {
        proto {
            srcDir("../../proto") // single source of truth, shared with the desktop
        }
    }
}

protobuf {
    protoc {
        artifact = libs.protoc.get().toString()
    }
    plugins {
        id("grpc") {
            artifact = libs.grpc.protoc.gen.java.get().toString()
        }
    }
    generateProtoTasks {
        all().forEach { task ->
            // Lite runtime: smaller, the Android-recommended protobuf flavor. The
            // `java` builtin is auto-registered, so configure it rather than re-add.
            task.builtins {
                getByName("java") { option("lite") }
            }
            task.plugins {
                id("grpc") { option("lite") }
            }
        }
    }
}

dependencies {
    api(libs.grpc.okhttp)        // client + lightweight server transport (Android-friendly)
    api(libs.grpc.protobuf.lite)
    api(libs.grpc.stub)
    api(libs.protobuf.javalite)
    compileOnly(libs.javax.annotation.api) // for @javax.annotation.Generated in stubs
}
