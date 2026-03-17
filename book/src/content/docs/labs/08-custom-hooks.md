---
title: "Lab 8: Building a Custom Hook Module"
description: "Package a WebView URL interceptor as a reusable patch-tool module"
---

> **Prerequisites:** Lab 7 complete, Gradle available (`./gradlew` wrapper included), Chapter 14 (Custom Hook Development) read.
>
> **Estimated time:** 60 minutes.
>
> **Chapter reference:** Chapter 14 -- Custom Hook Development.
>
> **Target:** `materials/targets/target-webview-app.apk` if available. If not present, use `materials/targets/target-kyc-basic.apk` as a fallback -- any app with `WebView.loadUrl()` calls will work.

In Lab 7 you edited smali by hand. That works for a single call-site. But when a target has `loadUrl()` calls in six different classes, manual editing becomes tedious and error-prone. This lab teaches you to build a reusable hook module that the patch-tool applies automatically to every matching call-site across the entire APK.

The target loads sensitive URLs in a WebView, including an authentication endpoint that passes a bearer token as a URL parameter. The token is not visible in the UI, not stored in SharedPreferences, and not in the APK's resources. It is constructed at runtime and passed to `WebView.loadUrl()`. Your hook module will intercept every `loadUrl()` call and log the URL to logcat, exposing the token.

This is the transition from artisan to arsenal. One hook module, applicable to any APK, forever.

---

## Step 1: Recon the Target

Decode and count all `loadUrl()` call-sites:

```bash
cd /Users/josejames/Documents/android-red-team
apktool d materials/targets/target-webview-app.apk -o decoded-webview/
```

If the target APK is not available, decode `materials/targets/target-kyc-basic.apk`:

```bash
apktool d materials/targets/target-kyc-basic.apk -o decoded-webview/
```

Find every `loadUrl()` call:

```bash
grep -rn "loadUrl" decoded-webview/smali*/
```

Count the results and note which classes contain them. Record this number -- you will use it to verify your hook's coverage later.

For each match, examine the line:

```smali
invoke-virtual {v3, v7}, Landroid/webkit/WebView;->loadUrl(Ljava/lang/String;)V
```

The second register (`v7` in this example) holds the URL string. Your hook needs to extract this register and pass it to `Log.d()`.

---

## Step 2: Write the Hook Module

Create `WebViewSmaliHook.kt` in the patch-tool's hooks directory. The module implements the `SmaliHookDefinition` interface:

```kotlin
class WebViewSmaliHook : SmaliHookDefinition {
    override val name = "WebViewUrlLogger"

    override fun apply(decodedDir: File, logger: Logger) {
        var totalPatched = 0

        findSmaliFiles(decodedDir).forEach { file ->
            val lines = file.readLines().toMutableList()
            var modified = false
            var i = 0

            while (i < lines.size) {
                val line = lines[i]

                // Match: invoke-virtual {vX, vY}, Landroid/webkit/WebView;->loadUrl(Ljava/lang/String;)V
                if (line.contains("WebView;->loadUrl") && line.contains("invoke-virtual")) {
                    // Extract the URL register (second register in the invoke)
                    val regMatch = Regex("""\{(\w+),\s*(\w+)\}""").find(line)
                    val urlReg = regMatch?.groupValues?.get(2)

                    if (urlReg != null) {
                        // Insert Log.d before the loadUrl call
                        val hook = listOf(
                            "    const-string v0, \"HookEngine\"",
                            "    invoke-static {v0, $urlReg}, Landroid/util/Log;->d(Ljava/lang/String;Ljava/lang/String;)I"
                        )
                        lines.addAll(i, hook)
                        i += hook.size  // skip past the inserted lines
                        totalPatched++
                        modified = true
                    }
                }
                i++
            }

            if (modified) {
                file.writeText(lines.joinToString("\n"))
            }
        }

        logger.info("[$name] Patched $totalPatched WebView.loadUrl() call-sites")
    }
}
```

**Key design decisions:**

1. **Register extraction:** The regex `\{(\w+),\s*(\w+)\}` captures both registers from the invoke instruction. The first is the WebView instance; the second is the URL string.
2. **Insert before, not after:** Unlike the SharedPreferences hook in Lab 7 (which captured the return value), `loadUrl()` returns `void`. You insert the log call *before* the `loadUrl()` invocation so you capture the URL even if `loadUrl()` throws.
3. **Using `v0` as scratch:** This assumes `v0` is safe to clobber at the insertion point. For a production-quality hook, you would bump `.locals` and use the new register. For this lab, `v0` works in most cases.

> **Register safety note:** If you encounter a target where clobbering `v0` causes a crash, add logic to your hook that reads the `.locals N` line and bumps it to `N+1`, then uses `vN` as the scratch register. See Chapter 13 for the `.locals` bumping pattern.

---

## Step 3: Test Your Hook Against the Decoded Directory

Before integrating with the patch-tool, test the scanning logic standalone:

```kotlin
fun main() {
    val decoded = File("decoded-webview/")
    val logger = Logger.getLogger("test")
    WebViewSmaliHook().apply(decoded, logger)
}
```

Run this from the command line or your IDE. Check the output:

```text
[WebViewUrlLogger] Patched N WebView.loadUrl() call-sites
```

Verify `N` matches the count from your Step 1 recon grep. If it does not, your regex is missing some call-site variants. Common variants to handle:

- `invoke-virtual/range` -- used when register numbers exceed 15
- Different whitespace formatting in the smali output
- `loadUrl(Ljava/lang/String;Ljava/util/Map;)V` -- the overload that takes extra headers

---

## Step 4: Register the Hook

Add your hook to the patch-tool's hook registry alongside the built-in hooks. The exact location depends on the project structure -- look for where `SmaliHookDefinition` implementations are registered:

```bash
grep -rn "SmaliHookDefinition\|hookRegistry\|addHook" patch-tool/src/
```

Add your class to the list:

```kotlin
val hooks = listOf(
    // ... existing hooks ...
    WebViewSmaliHook()
)
```

---

## Step 5: Build and Run

Rebuild the patch-tool with your new hook:

```bash
./gradlew :patch-tool:fatJar
```

Run it against the target:

```bash
java -jar patch-tool/build/libs/patch-tool.jar \
  materials/targets/target-webview-app.apk \
  --out webview-patched.apk --work-dir ./work-webview
```

Check the output for:

- `[*] Applying WebView URL Logger...` -- your hook was discovered
- `[+] Patched N WebView.loadUrl() call-sites` -- it found and patched the targets

If the patch-tool does not discover your hook, verify it is registered in the hook list and that `./gradlew :patch-tool:fatJar` completed without errors.

---

## Step 6: Deploy and Capture

```bash
adb install -r webview-patched.apk

# Launch (replace with actual package/activity)
adb shell am start -n <package>/<launcher_activity>

# Watch for intercepted URLs
adb logcat -s HookEngine
```

Navigate through the app. Every URL loaded in a WebView appears in logcat. One of them contains the authentication token.

Expected output:

```text
D HookEngine: https://app.example.com/dashboard
D HookEngine: https://auth.example.com/verify?token=eyJhbG...
D HookEngine: https://app.example.com/profile
```

The URL containing `token=` or `bearer=` or similar is your finding.

---

## Step 7: Document the Finding

Record:

1. **Total call-sites patched:** the count from the patch-tool output
2. **Authentication URL:** the full URL including the token parameter
3. **Class and method:** which smali class contained the authentication `loadUrl()` call
4. **Token value:** extract and document the bearer token

---

## Deliverables

| Artifact | Description |
|----------|-------------|
| `WebViewSmaliHook.kt` | Complete hook module source |
| Patch-tool output | Console output showing your hook discovered and applied |
| Logcat capture | `HookEngine` output with intercepted URLs |
| Finding summary | The authentication URL and extracted token |

---

## Success Criteria

- [ ] Hook module compiles and is discovered by the patch-tool
- [ ] All `loadUrl()` call-sites are patched (count matches recon)
- [ ] App launches without crashing after patching
- [ ] Logcat shows intercepted URLs with the `HookEngine` tag
- [ ] Authentication token is visible in the captured URLs

---

## Self-Check Script

```bash
#!/usr/bin/env bash
echo "=========================================="
echo "  LAB 8: CUSTOM HOOK MODULE SELF-CHECK"
echo "=========================================="
PASS=0; FAIL=0

# Check that the hook module source exists
HOOK_FILE=$(find /Users/josejames/Documents/android-red-team -name "WebViewSmaliHook.kt" -not -path "*/build/*" 2>/dev/null | head -1)
if [ -n "$HOOK_FILE" ]; then
  echo "  [PASS] WebViewSmaliHook.kt found: $HOOK_FILE"
  ((PASS++))
else
  echo "  [FAIL] WebViewSmaliHook.kt not found"
  ((FAIL++))
fi

# Check that the patch-tool builds
if [ -f patch-tool/build/libs/patch-tool.jar ]; then
  echo "  [PASS] patch-tool.jar built"
  ((PASS++))
else
  echo "  [FAIL] patch-tool.jar not found -- run: ./gradlew :patch-tool:fatJar"
  ((FAIL++))
fi

# Check that the patched APK exists
if [ -f webview-patched.apk ]; then
  echo "  [PASS] webview-patched.apk built"
  ((PASS++))
else
  echo "  [FAIL] webview-patched.apk not found"
  ((FAIL++))
fi

# Check logcat for intercepted URLs
URL_LINES=$(adb logcat -d -s HookEngine 2>/dev/null | grep -ci "http\|url\|load")
echo "  Intercepted URL log lines: $URL_LINES"
if [ "$URL_LINES" -gt 0 ]; then
  echo "  [PASS] URLs captured in logcat"
  ((PASS++))
else
  echo "  [FAIL] No URL intercepts found"
  ((FAIL++))
fi

# Check for auth token in logs
TOKEN_FOUND=$(adb logcat -d -s HookEngine 2>/dev/null | grep -ci "token\|auth\|bearer")
if [ "$TOKEN_FOUND" -gt 0 ]; then
  echo "  [PASS] Auth token visible in logs"
  ((PASS++))
else
  echo "  [WARN] No obvious token found -- review full HookEngine output manually"
fi

echo ""
echo "  Results: $PASS passed, $FAIL failed"
echo ""
echo "  Manual checks:"
echo "    1. Verify WebViewSmaliHook implements SmaliHookDefinition interface"
echo "    2. Confirm loadUrl() call-site count matches your recon grep count"
echo "    3. Identify which URL contains the authentication token"
echo "=========================================="
[ "$FAIL" -eq 0 ] && echo "  Lab 8 COMPLETE." || echo "  Lab 8 INCOMPLETE -- review failed checks."
```

---

## What You Just Demonstrated

You built a reusable capability that did not exist before. Your `WebViewSmaliHook` will intercept `loadUrl()` in any APK the patch-tool processes -- not just this target. The next time you encounter an app that passes sensitive data through WebViews, you run the patch-tool and the interception is automatic.

This is how the toolkit grows. Each engagement teaches you about a new API pattern. Each pattern becomes a hook module. Each module becomes a permanent part of your arsenal. Over time, the patch-tool evolves from a camera/GPS/sensor injection tool into a comprehensive Android instrumentation platform -- custom-tailored to the targets you actually encounter.

The pattern is always the same: identify the API, find the call-site signature, write the regex to match it, insert the interception code, and register the module. Lab 7 gave you the smali fundamentals. This lab gave you the automation framework. Everything from here is application.
