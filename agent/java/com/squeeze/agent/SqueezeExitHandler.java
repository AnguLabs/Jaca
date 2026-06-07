package com.squeeze.agent;

/**
 * Bridge between the bootstrap trampoline ({@link SqueezeHooks}) and the Kotlin
 * capture code on its own class loader. Pure Java + on the bootstrap class loader
 * so instrumented boot classes can reference it without pulling in Kotlin's stdlib.
 */
public interface SqueezeExitHandler {
    Object onExit(String methodSignature, Object returnObject);
}
