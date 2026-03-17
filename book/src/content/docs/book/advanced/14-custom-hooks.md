---
title: "Building Custom Hooks"
description: "Package manual smali techniques into reusable patch-tool modules"
---

Chapter 13 taught you to edit smali by hand -- open a file, find the target, insert two lines, rebuild. That is manual surgery. It works. It is precise. And it is terrible at scale. If you need to apply the same hook to twenty APKs, or if the target method appears in fifteen different smali files, hand-editing every one is a recipe for mistakes and wasted time.

This chapter teaches you to package your hook as a module that the patch-tool applies automatically. You write a Kotlin class that implements `SmaliHookDefinition`, and the patch-tool discovers it, runs it against every decoded APK, and applies your hook everywhere it matches. One command. Any APK. Your custom hook fires alongside the built-in camera, location, and sensor hooks.

This is the difference between a one-off exploit and a reusable capability. Once your hook module is written, it is part of the arsenal. Every future engagement benefits from it.

> **Prerequisites:** This chapter requires a Kotlin/Gradle development environment. If you followed the minimal setup in Chapter 4, you will also need Kotlin support. The `gradlew` wrapper in the project root handles Gradle installation automatically -- just run `./gradlew` and it will download what it needs.

---

## How the Patch-Tool Discovers Hooks

The patch-tool maintains a registry of `SmaliHookDefinition` implementations. Each hook module is a Kotlin class that:

1. Has a name (e.g., `"camerax"`, `"location"`, `"sensor"`)
2. Knows how to find its target methods in decoded smali (via grep patterns)
3. Knows how to patch those methods (using the three patterns from Chapter 13)

The existing built-in hooks:

| Hook Class | Name | What it patches |
|-----------|------|----------------|
| `CoreSmaliHook` | `core` | `Application.onCreate()` -- bootstrap |
| `CameraXSmaliHook` | `camerax` | `toBitmap()`, `analyze()`, `onCaptureSuccess()` |
| `Camera2SmaliHook` | `camera2` | `Surface()`, `getSurface()`, `OnImageAvailableListener` |
| `LocationSmaliHook` | `location` | `onLocationResult()`, `onLocationChanged()`, mock detection |
| `SensorSmaliHook` | `sensor` | `onSensorChanged()` |

Your custom hook becomes the sixth (or seventh, or eighth) entry in this list.

---

## The SmaliHookDefinition Interface

The interface itself is minimal:

```kotlin
interface SmaliHookDefinition {
    val name: String
    fun apply(decodedDir: File, logger: Logger)
}
```

`findSmaliFiles` is NOT part of the interface -- it is a utility function you write yourself (shown later in "Common Utility Patterns").

Every hook module implements the same interface:

```kotlin
class MyCustomHook : SmaliHookDefinition {
    override val name = "my-hook"

    override fun apply(decodedDir: File, logger: Logger) {
        // decodedDir = root of apktool-decoded APK
        // smali files are in decodedDir/smali/, smali_classes2/, etc.

        // Step 1: Find target smali files
        val targets = findSmaliFiles(decodedDir, "TargetMethodPattern")

        // Step 2: For each target, apply the patch
        for (file in targets) {
            val lines = file.readLines().toMutableList()
            // ... find and modify target lines ...
            file.writeText(lines.joinToString("\n"))
        }

        logger.info("[+] Patched ${targets.size} file(s)")
    }
}
```

That is it. The patch-tool calls `apply()` with the path to the decoded APK, and your hook does whatever it needs to the smali files. It is just string manipulation of text files -- grep for patterns, find the right line, insert or replace.

---

## Anatomy of a Real Hook

Let us walk through `CameraXSmaliHook.patchAnalyzer()` -- the hook that intercepts the camera analysis pipeline:

1. **Search** decoded smali for files containing `ImageAnalysis$Analyzer`
2. For each file, **find** the `analyze(Landroidx/camera/core/ImageProxy;)V` method
3. **Find** the `.registers` or `.locals` line (first one after `.method`)
4. **Insert** the two-line hook right after it:
   ```smali
   invoke-static {p1}, Lcom/hookengine/core/FrameInterceptor;->intercept(...)...
   move-result-object p1
   ```
5. **Verify** register counts are sufficient (no bump needed -- we reuse `p1`)

The location mock detection hook (`LocationSmaliHook.patchMockDetection()`) works differently -- it is a call-site interception:

1. **Search** for `invoke-virtual.*isFromMockProvider`
2. **Find** the `move-result` after it
3. **Replace** the result with `const/4 vN, 0x0` (force `false`)

Both are just string operations on smali text files. Grep, find the line, insert or replace.

---

## Building Your Own Hook Module

### Step 1: Create the file

Create `YourHook.kt` in the patch-tool's hooks directory (alongside `CameraXSmaliHook.kt`, `LocationSmaliHook.kt`, etc.).

### Step 2: Implement the interface

```kotlin
class WebViewUrlLoggerHook : SmaliHookDefinition {
    override val name = "webview-logger"

    override fun apply(decodedDir: File, logger: Logger) {
        val files = findSmaliFiles(decodedDir, "loadUrl")
        var patchCount = 0

        for (file in files) {
            val lines = file.readLines().toMutableList()
            var i = 0
            while (i < lines.size) {
                val line = lines[i].trim()
                if (line.contains("WebView;->loadUrl(Ljava/lang/String;)V")) {
                    // The loadUrl call looks like: invoke-virtual {vX, vY}, ...WebView;->loadUrl(String)V
                    // vY is the URL string register. Extract it from the invoke line.
                    val urlReg = line.substringAfter("{").substringBefore("}").split(",").last().trim()
                    // Insert Log.d() before the loadUrl call
                    val hookLines = listOf(
                        "    const-string v0, \"HookEngine\"",
                        "    invoke-static {v0, $urlReg}, Landroid/util/Log;->d(Ljava/lang/String;Ljava/lang/String;)I"
                    )
                    lines.addAll(i, hookLines)
                    i += hookLines.size
                    patchCount++
                }
                i++
            }
            if (patchCount > 0) file.writeText(lines.joinToString("\n"))
        }
        logger.info("[+] Patched $patchCount WebView.loadUrl() call-sites")
    }
}
```

### Step 3: Register it

In the patch-tool's hook registry (`ApkPatcher.kt` or equivalent), add your hook to the list:

```kotlin
val hooks = listOf(
    CoreSmaliHook(),
    CameraXSmaliHook(),
    Camera2SmaliHook(),
    LocationSmaliHook(),
    SensorSmaliHook(),
    WebViewUrlLoggerHook()    // <-- your hook
)
```

### Step 4: Build and test

```bash
# Rebuild the patch-tool with your hook
./gradlew :patch-tool:fatJar

# Run against a target -- your hook is now part of the pipeline
java -jar patch-tool/build/libs/patch-tool.jar target.apk --out patched.apk

# Check output for your hook's log messages
# [*] Applying WebView URL Logger...
# [+] Patched 3 WebView.loadUrl() call-sites
```

---

## Complete Worked Example: SharedPreferences Extraction Hook

This section builds a complete hook module from scratch. The scenario: during an engagement, you discover that the target stores OAuth refresh tokens, session identifiers, and biometric enrollment flags in `SharedPreferences`. The built-in hooks do not cover this API surface. You need a reusable module that intercepts every `getString()` call on any `SharedPreferences` instance and logs the key-value pair to logcat.

### Step 1: Recon -- Find getString() Calls in Smali

First, confirm that the target actually uses `SharedPreferences.getString()`. Decode the APK and search:

```bash
grep -rn "invoke-interface.*SharedPreferences;->getString" work/smali*/
```

Expected output (from a real decoded APK):

```text
smali/com/target/app/TokenManager.smali:47:    invoke-interface {v0, v1, v2}, Landroid/content/SharedPreferences;->getString(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;
smali/com/target/app/Config.smali:83:    invoke-interface {v3, v4, v5}, Landroid/content/SharedPreferences;->getString(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;
smali_classes2/com/target/app/SessionHelper.smali:29:    invoke-interface {v0, v1, v2}, Landroid/content/SharedPreferences;->getString(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;
```

Three call sites across two DEX files. Manual patching would work, but if the next APK version adds more call sites, you would have to repeat the analysis. A hook module handles it automatically.

### Step 2: Design the Hook

This is a Pattern 2 (call-site interception) hook. The target is:

```smali
invoke-interface {vA, vB, vC}, Landroid/content/SharedPreferences;->getString(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;
move-result-object vD
```

After the `move-result-object`, register `vD` holds the value returned by `getString()`. Register `vB` holds the key that was requested. We want to log both the key and the value.

The challenge: we need two scratch registers for the log tag and the formatted message. Rather than bumping `.locals` (which requires tracking the register count for every method we patch), we will write a static helper method that takes the key and value as parameters and handles the logging internally. This way the injection site needs zero extra registers -- we just pass the two registers we already have.

### Step 3: Write the Hook Class

```kotlin
class SharedPrefsExtractionHook : SmaliHookDefinition {
    override val name = "sharedprefs-extractor"

    override fun apply(decodedDir: File, logger: Logger) {
        // Inject the helper smali class into the runtime DEX slot
        injectHelperClass(decodedDir, logger)

        // Find and patch all SharedPreferences.getString() call sites
        val files = findSmaliFiles(decodedDir, "SharedPreferences;->getString")
        var patchCount = 0

        for (file in files) {
            val lines = file.readLines().toMutableList()
            var i = 0
            while (i < lines.size) {
                val line = lines[i].trim()

                // Match the getString invoke
                if (line.contains("SharedPreferences;->getString(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;")) {
                    // Extract the key register (second register in the invoke)
                    val regs = line.substringAfter("{").substringBefore("}").split(",").map { it.trim() }
                    // regs[0] = SharedPreferences object, regs[1] = key, regs[2] = default value
                    val keyReg = regs.getOrNull(1) ?: continue

                    // Find the move-result-object on the next line
                    if (i + 1 < lines.size && lines[i + 1].trim().startsWith("move-result-object")) {
                        val resultReg = lines[i + 1].trim().removePrefix("move-result-object").trim()

                        // Insert the logging call after the move-result-object
                        val hookLine = "    invoke-static {$keyReg, $resultReg}, Lcom/hookengine/hooks/PrefsLogger;->log(Ljava/lang/String;Ljava/lang/String;)V"
                        lines.add(i + 2, hookLine)
                        patchCount++
                        i++ // skip past the line we just inserted
                    }
                }
                i++
            }

            if (patchCount > 0) {
                file.writeText(lines.joinToString("\n"))
            }
        }

        logger.info("[+] Patched $patchCount SharedPreferences.getString() call-sites")
    }

    private fun injectHelperClass(decodedDir: File, logger: Logger) {
        // Find the runtime DEX slot (smali_classes7/ or wherever the runtime lives)
        val runtimeDir = decodedDir.listFiles()
            ?.filter { it.name.startsWith("smali") }
            ?.sortedByDescending { it.name }
            ?.firstOrNull { File(it, "com/hookengine").exists() }
            ?: return

        val targetDir = File(runtimeDir, "com/hookengine/hooks")
        targetDir.mkdirs()

        val smaliContent = """
.class public Lcom/hookengine/hooks/PrefsLogger;
.super Ljava/lang/Object;

.method public static log(Ljava/lang/String;Ljava/lang/String;)V
    .locals 2
    const-string v0, "PrefsExtractor"
    new-instance v1, Ljava/lang/StringBuilder;
    invoke-direct {v1}, Ljava/lang/StringBuilder;-><init>()V
    invoke-virtual {v1, p0}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;
    const-string v0, " = "
    invoke-virtual {v1, v0}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;
    invoke-virtual {v1, p1}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;
    invoke-virtual {v1}, Ljava/lang/StringBuilder;->toString()Ljava/lang/String;
    move-result-object v1
    const-string v0, "PrefsExtractor"
    invoke-static {v0, v1}, Landroid/util/Log;->d(Ljava/lang/String;Ljava/lang/String;)I
    return-void
.end method
        """.trimIndent()

        File(targetDir, "PrefsLogger.smali").writeText(smaliContent)
        logger.info("[+] Injected PrefsLogger helper class")
    }
}
```

The helper class `PrefsLogger` lives alongside the existing runtime classes in the injected DEX slot. It takes the key and value as parameters and writes a formatted log line. This keeps the injection site to a single line of smali -- no register bumping, no multi-line insertions, minimal risk of breaking the target method.

### Step 4: Register, Build, Test

Add the hook to the registry:

```kotlin
val hooks = listOf(
    CoreSmaliHook(),
    CameraXSmaliHook(),
    Camera2SmaliHook(),
    LocationSmaliHook(),
    SensorSmaliHook(),
    SharedPrefsExtractionHook()    // <-- new
)
```

Build and run:

```bash
./gradlew :patch-tool:fatJar

java -jar patch-tool/build/libs/patch-tool.jar target.apk \
    --out patched.apk --work-dir ./work
```

Check the output for your hook's messages:

```text
[*] Applying SharedPrefs Extractor...
[+] Injected PrefsLogger helper class
[+] Patched 3 SharedPreferences.getString() call-sites
```

### Step 5: Verify in Logcat

Install and launch the patched APK, then filter logcat:

```bash
adb install -r patched.apk
adb shell monkey -p com.target.app -c android.intent.category.LAUNCHER 1
adb logcat -s PrefsExtractor
```

Expected output:

```text
D/PrefsExtractor: session_token = eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...
D/PrefsExtractor: refresh_token = dGhpcyBpcyBhIHJlZnJlc2ggdG9rZW4...
D/PrefsExtractor: enrollment_status = COMPLETE
```

Every `getString()` call in the entire app now logs its key and value. You see every preference the app reads, every token it retrieves, every flag it checks. The hook fires on all three call sites you found during recon, and it will fire on any new call sites added in future versions -- because the pattern match is structural, not positional.

---

## Common Utility Patterns

### Finding smali files containing a pattern

```kotlin
fun findSmaliFiles(decoded: File, pattern: String): List<File> {
    val results = mutableListOf<File>()
    for (dir in decoded.listFiles() ?: emptyArray()) {
        if (!dir.name.startsWith("smali")) continue
        dir.walkTopDown().filter { it.extension == "smali" }.forEach { file ->
            if (file.readText().contains(pattern)) results.add(file)
        }
    }
    return results
}
```

### Finding a method in a smali file

Scan line by line, tracking when you are inside the target method:

```kotlin
var insideMethod = false
for ((index, line) in lines.withIndex()) {
    if (line.trim().startsWith(".method") && line.contains("targetMethodName")) {
        insideMethod = true
    }
    if (insideMethod && line.trim() == ".end method") {
        insideMethod = false
    }
    if (insideMethod && line.trim().startsWith(".registers")) {
        // Insert hook on the NEXT line
        insertionPoint = index + 1
    }
}
```

### Safely bumping register count

```kotlin
// If using .locals (safer -- params don't shift):
val localsLine = lines[localsIndex]
val currentLocals = localsLine.trim().removePrefix(".locals ").toInt()
lines[localsIndex] = "    .locals ${currentLocals + 1}"
// New scratch register = v{currentLocals}
```

---

## Dealing with Obfuscation

ProGuard/R8 renames classes and methods to single letters (`a`, `b`, `c`). This affects your hooks in two ways:

1. **Framework API calls survive obfuscation.** Hooks targeting `WebView;->loadUrl` still work because Android framework method names are never obfuscated.
2. **App-internal methods break.** A custom `verifyFace()` becomes `a()`. For these, match on *structure* (method signature, parameter types) rather than name.

Tools like `jadx` can help map obfuscated names back to their likely original purpose.

When writing hook modules for obfuscated targets, prefer these strategies:

- **Target framework APIs exclusively** when possible. `SharedPreferences.getString()`, `WebView.loadUrl()`, `HttpURLConnection.getInputStream()` -- these signatures are stable across every obfuscated and unobfuscated APK.
- **Match on parameter and return types** when you must hook an app-internal method. Instead of `grep "verifyFace"`, use `grep "\.method.*\(Landroid/graphics/Bitmap;\)Z"` to find methods that take a Bitmap and return a boolean.
- **Use string constants as anchors.** If you know the obfuscated method logs `"face_verification_complete"` or accesses a preference key `"biometric_enrolled"`, search for that string and work backward to the method that references it.

---

## When to Write a Custom Hook

Write a custom hook when:
- The target uses a **non-standard API** not covered by built-in hooks
- You need to intercept **application-specific methods** (custom wrappers, proprietary SDKs)
- You want to **log or extract data** from specific API calls (SharedPreferences, WebView, network, crypto)
- You need to **bypass custom defenses** (anti-tamper checks, custom mock detection)

Do not write a custom hook when:
- The built-in hooks already cover the API path
- A one-off manual edit is sufficient (Chapter 13 technique)
- You need the hook for only one specific APK version (manual is faster)

The rule of thumb: if you will apply the same patch to three or more APKs, write a hook module. The twenty minutes you spend writing the Kotlin class saves hours of manual edits across future engagements.

### Common Hook Ideas

To give you a sense of what custom hooks look like in practice, here are modules that have proven useful across real engagements:

| Hook Name | Target API | Purpose |
|-----------|-----------|---------|
| `sharedprefs-extractor` | `SharedPreferences.getString()` | Extract auth tokens, session IDs, enrollment flags |
| `webview-logger` | `WebView.loadUrl()` | Log every URL the app loads, including OAuth callbacks |
| `cert-pin-bypass` | `CertificatePinner.check()` | Neutralize OkHttp certificate pinning |
| `crypto-logger` | `Cipher.doFinal()` | Log encrypted payloads before encryption and after decryption |
| `signature-bypass` | `PackageManager.getPackageInfo()` | Return the original signature when the app checks APK integrity |
| `root-detect-bypass` | Various root detection methods | Force root check methods to return false |

Each of these follows the same pattern: find the framework API call in the smali, determine which registers hold the interesting data, insert one or two lines to log or replace the values. The SharedPreferences hook we built above is a template you can adapt for any of these scenarios.

---

## Testing Workflow for Custom Hooks

A custom hook that works on your development machine but crashes on the target device is worse than no hook at all. Build a testing discipline that catches errors before they reach a real engagement.

### Unit Testing: Validate Patch Logic

The `apply()` method operates on a directory of text files. You do not need an Android device or even an APK to test the core logic. Create a test fixture: a directory containing minimal smali files with the patterns your hook targets.

```kotlin
@Test
fun testSharedPrefsHookInsertion() {
    // Create a temporary directory with a minimal smali file
    val tempDir = Files.createTempDirectory("hook-test").toFile()
    val smaliDir = File(tempDir, "smali/com/test").apply { mkdirs() }

    File(smaliDir, "TestClass.smali").writeText("""
.class public Lcom/test/TestClass;
.super Ljava/lang/Object;

.method public readToken()Ljava/lang/String;
    .locals 3
    iget-object v0, p0, Lcom/test/TestClass;->prefs:Landroid/content/SharedPreferences;
    const-string v1, "token"
    const-string v2, ""
    invoke-interface {v0, v1, v2}, Landroid/content/SharedPreferences;->getString(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;
    move-result-object v0
    return-object v0
.end method
    """.trimIndent())

    // Also create the runtime directory so the helper class injection works
    File(tempDir, "smali_classes7/com/hookengine").mkdirs()

    // Run the hook
    val hook = SharedPrefsExtractionHook()
    hook.apply(tempDir, testLogger)

    // Verify the patch was applied
    val patched = File(smaliDir, "TestClass.smali").readText()
    assertTrue(patched.contains("PrefsLogger;->log"))
    assertTrue(File(tempDir, "smali_classes7/com/hookengine/hooks/PrefsLogger.smali").exists())

    tempDir.deleteRecursively()
}
```

Run this with `./gradlew test`. The test verifies two things: the hook found the target pattern and inserted the call, and the helper class was written to the correct location. No device needed. No APK needed. Runs in milliseconds.

### Integration Testing: Patch a Real APK

Unit tests validate the logic. Integration tests validate the result.

```bash
# Patch a known APK
java -jar patch-tool/build/libs/patch-tool.jar target.apk \
    --out patched.apk --work-dir ./work

# Verify the hook was applied in the smali
grep -rn "PrefsLogger" ./work/smali*/

# Install and launch
adb install -r patched.apk
adb shell monkey -p com.target.app -c android.intent.category.LAUNCHER 1

# Watch for output
adb logcat -s PrefsExtractor | head -20
```

If you see your log tag in logcat, the integration test passes. If the app crashes, the error will be in logcat. The two most common integration failures:

**`VerifyError` at launch** -- Your injected smali has a type error or register overflow. The Dalvik verifier catches this at class load time. Open the patched smali in `./work/` and check: Did you use a register that does not exist? Did you pass the wrong type to an invoke? Did you forget the `move-result-object` after an invoke that returns a value?

**`ClassNotFoundException` for the helper class** -- The helper smali was written to the wrong directory, or the smali file has a syntax error that prevents it from compiling into the DEX. Check that the `.class` directive in the helper smali matches the path you call from the injection site. Check that the helper file is inside a `smali_classesN/` directory that the patch-tool compiles.

**Wrong register in the invoke** -- The most insidious failure. The hook applies cleanly. The APK installs and launches. But the logged values are garbage -- wrong strings, null where you expected data, or the app crashes on a specific code path. This means you extracted the wrong register from the `invoke-interface` line. Go back to the target smali file, manually trace the registers in the method, and verify that the register you pass to your helper actually holds the value you think it does.

### The Debug Log Ladder

When a hook is not working and you cannot tell why, insert progressively more detailed log statements:

1. Log at the injection point: "Hook reached getString call site"
2. Log the register values: pass each register to `Log.d()` individually
3. Log inside the helper class: confirm the helper is being called and what it receives
4. Log the method name and class: use the smali file path to trace which method fired

Each level of logging narrows the problem. Once you find the issue, remove the debug logs and rebuild.

### Regression Testing Across APK Versions

Targets update. When version 3.2 ships and the client asks for a re-test, your hook needs to work on the new APK without modification. Build a regression test into your workflow:

1. Keep a collection of decoded smali directories from previous target versions (one per version, stored in your engagement archive).
2. When you update the patch-tool, run your hook's `apply()` against every archived version.
3. Verify that the patch count is non-zero for each version and that the injected lines appear in the expected locations.

This takes seconds per version and catches pattern drift before it reaches a live engagement. If a new version breaks your hook, you discover it on your workstation, not in front of a client.

---

## Packaging and Distributing Hook Modules

### Fat JAR Packaging

The patch-tool builds as a fat JAR -- a single `.jar` file containing all dependencies, all hook modules, and the runtime classes. When you add a new hook, it becomes part of the fat JAR on the next build:

```bash
./gradlew :patch-tool:fatJar
```

The output at `patch-tool/build/libs/patch-tool.jar` contains your custom hook alongside every built-in hook. Distribute this single file to your team. Anyone who runs it gets your hook automatically.

### Sharing Hooks Across Team Members

The simplest distribution model: commit your hook class to the patch-tool's source repository and let team members pull and build. Every `./gradlew :patch-tool:fatJar` produces an identical artifact with the full hook set.

For teams that do not want to share source, distribute the built fat JAR directly. Place it in a shared location (internal artifact repository, shared drive, team wiki attachment) and version it. Use semantic versioning: bump the minor version when you add a hook, bump the patch version when you fix a hook.

### Version Compatibility

Hook modules target smali patterns, not APK versions. A hook that matches `SharedPreferences;->getString` works on every Android APK regardless of target SDK version, because the `SharedPreferences` interface has not changed since API 1.

The risk is not Android version incompatibility. It is **pattern drift**: the target app changes its code structure between versions. A method that called `getString()` directly in version 3.1 might wrap it in a helper class in version 3.2. Your hook still matches the `getString()` call, but now it is in a different smali file, inside a different method, with different registers. The hook module handles this gracefully -- it searches all smali files, not a hardcoded path -- but the register extraction logic might need to account for new patterns.

Build hooks defensively. Log a warning when zero matches are found (the pattern may have moved). Log a warning when an unexpected number of matches are found (the pattern may have proliferated). Treat the match count as a signal, not just a metric.

---

## Key Takeaways

- A hook module is a Kotlin class implementing `SmaliHookDefinition` with a `name` and `apply()` method
- Use utility patterns: `findSmaliFiles()`, method-finding, register bumping
- Framework API hooks survive ProGuard; app-internal hooks need structural matching
- Write a helper smali class for complex logging -- it keeps the injection site minimal and register-safe
- Unit test with mock directories before integration testing on real APKs
- Distribute via fat JAR; version the artifact so the team always knows which hooks are included
- Rule of thumb: write a hook module when you will apply the same patch to three or more APKs

The pattern is always the same: search the smali for a framework API signature, find the registers involved, insert one or two lines that route data through your code. Chapter 13 gave you the language. This chapter gave you the packaging. Together, they let you extend the toolkit to cover any API surface you encounter -- not just the cameras, locations, and sensors the built-in hooks address, but SharedPreferences, WebViews, network calls, crypto operations, and any proprietary SDK the target embeds.

**Practice:** Lab 8 (Custom Hooks) walks you through building a complete hook module from scratch and testing it against the target APK.

Next: Chapter 15 applies these skills to the hardest targets -- applications that use server-side challenge-response protocols, certificate pinning, and runtime integrity checks designed specifically to resist the kind of instrumentation you have been doing.
