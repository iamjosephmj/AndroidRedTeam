---
title: "Lab 7: Manual Smali Hooking"
description: "Intercept SharedPreferences data by hand-editing smali bytecode"
---

> **Prerequisites:** Labs 0-6 complete, Chapter 13 (Smali Bytecode Fundamentals) read.
>
> **Estimated time:** 45-60 minutes.
>
> **Chapter reference:** Chapter 13 -- Smali Bytecode Fundamentals.
>
> **Target:** `materials/targets/target-sharedprefs.apk` if available. If not present, use [`materials/targets/target-kyc-basic.apk`](https://github.com/iamjosephmj/AndroidRedTeam/blob/main/materials/targets/target-kyc-basic.apk) as a fallback -- any app that calls `SharedPreferences.getString()` will work.

Every lab until now used the patch-tool to apply hooks automatically. You never touched smali. The tool found the right methods, inserted the right code, and rebuilt the APK. That changes here.

In this lab, you will write your first raw smali hook by hand. The target stores a secret authentication token in `SharedPreferences` and displays "Authenticated" when the token matches a hardcoded value. The token is not visible in the UI, not in string resources, and not deducible from static inspection alone -- it is computed at runtime. You will intercept the `SharedPreferences.getString()` call that reads it, log the key and value to logcat, and expose the secret.

The pattern you learn here is the same pattern the patch-tool uses internally for every hook it applies. The difference: the patch-tool automates the search-and-insert for known API signatures. For unknown or custom APIs, you do it yourself.

---

## Smali Quick Reference

Before you start editing bytecode, internalize these fundamentals:

| Concept | Syntax | Example |
|---------|--------|---------|
| Local registers | `v0` through `vN` | `v0`, `v3`, `v6` |
| Parameter registers | `p0` through `pN` (`p0` = `this`) | `p0`, `p1` |
| Call a static method | `invoke-static {args}` | `invoke-static {v0, v1}, Landroid/util/Log;->d(...)I` |
| Call an instance method | `invoke-virtual {obj, args}` | `invoke-virtual {v2, v3}, L...;->getString(...)` |
| Call an interface method | `invoke-interface {obj, args}` | `invoke-interface {v2, v3, v4}, L...SharedPreferences;->getString(...)` |
| Capture return value | `move-result-object vN` | `move-result-object v5` |
| Load a string constant | `const-string vN, "text"` | `const-string v0, "HookEngine"` |

**Register safety rule:** `.locals N` at the top of a method declares N local registers (`v0` through `v(N-1)`). Parameter registers (`pN`) follow immediately after. If you need a scratch register that is guaranteed free, bump `.locals N` to `.locals N+1` and use `vN` as your scratch.

---

## Step 1: Decode and Locate the Target

Decode the APK:

```bash
cd /Users/josejames/Documents/android-red-team
apktool d materials/targets/target-sharedprefs.apk -o decoded-prefs/
```

If the target APK is not available, decode [`materials/targets/target-kyc-basic.apk`](https://github.com/iamjosephmj/AndroidRedTeam/blob/main/materials/targets/target-kyc-basic.apk) instead:

```bash
apktool d materials/targets/target-kyc-basic.apk -o decoded-prefs/
```

Now find every class that calls `SharedPreferences.getString()`:

```bash
grep -rn "getString" decoded-prefs/smali*/ | grep -i "SharedPreferences"
```

This returns one or more file paths. Open each match and read the surrounding method. You are looking for a pattern like this:

```smali
invoke-interface {v2, v3, v4}, Landroid/content/SharedPreferences;->getString(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;
move-result-object v5
```

Break this down register by register:

| Register | Role |
|----------|------|
| `v2` | The `SharedPreferences` instance (the object the method is called on) |
| `v3` | The key string (the name of the preference being read) |
| `v4` | The default value (returned if the key does not exist) |
| `v5` | The returned value (captured by `move-result-object`) |

Record the exact file path, method name, and register numbers. You will need all three for the next step.

---

## Step 2: Trace the Register Flow

Before inserting any code, read the method from top to bottom and trace every register assignment. This prevents you from clobbering a register that is still in use.

Find the `.locals` declaration at the top of the method:

```smali
.locals 6
```

This means registers `v0` through `v5` are local. Parameters start at `p0`. List what each register holds at the point where `getString()` is called:

| Register | Contents at call site |
|----------|----------------------|
| `v0` | (trace from assignments above) |
| `v1` | (trace from assignments above) |
| `v2` | SharedPreferences instance |
| `v3` | Key string |
| `v4` | Default value |
| `v5` | (about to receive the return value) |

**Check which registers are free after `move-result-object`.** If `v0` is reassigned before the `getString()` call and not read again until after your insertion point, it is safe to reuse. If you are unsure, bump `.locals` by 1 and use the new register.

Example: if `.locals 6`, change to `.locals 7` and your scratch register is `v6`.

---

## Step 3: Insert the Log Hook

You are going to use **call-site interception**: insert code immediately after the `move-result-object` that captures the return value, before the app does anything else with it.

After `move-result-object v5`, insert:

```smali
# --- HOOK START: Log SharedPreferences value ---
const-string v6, "HookEngine"
invoke-static {v6, v5}, Landroid/util/Log;->d(Ljava/lang/String;Ljava/lang/String;)I
# --- HOOK END ---
```

This logs the returned value (the secret token) to logcat under the tag `HookEngine`. The `v6` register holds the tag string -- this is the scratch register you got by bumping `.locals`.

**If you also want to log the key**, add a second `Log.d()` call using the key register (`v3` in the example above):

```smali
const-string v6, "HookEngine"
invoke-static {v6, v3}, Landroid/util/Log;->d(Ljava/lang/String;Ljava/lang/String;)I
invoke-static {v6, v5}, Landroid/util/Log;->d(Ljava/lang/String;Ljava/lang/String;)I
```

**Do not forget to bump `.locals`.** If the original method has `.locals 6` and you use `v6`, change it to `.locals 7`. This is the single most common cause of smali build failures.

---

## Step 4: Verify the Smali Syntax

Before rebuilding, check your edit for common errors:

1. **Register count:** `.locals` was bumped to accommodate your scratch register.
2. **Type signatures:** `Landroid/util/Log;->d(Ljava/lang/String;Ljava/lang/String;)I` -- note the `L` prefix, semicolons, and `I` return type (integer).
3. **Register types:** `v5` must hold a `String` at the point you pass it to `Log.d()`. If `getString()` returned it, it is a `String` -- confirmed.
4. **No dangling labels:** Your insertion is between `move-result-object` and the next instruction. You did not insert inside a `try`/`catch` boundary or break a label chain.

Run a quick diff to confirm your changes are isolated:

```bash
diff decoded-prefs/smali*/com/path/to/TargetClass.smali.orig \
     decoded-prefs/smali*/com/path/to/TargetClass.smali
```

(If you made a backup before editing. If not, the git diff or a manual visual review works.)

---

## Step 5: Rebuild, Sign, and Install

```bash
# Rebuild the APK from the modified smali
apktool b decoded-prefs/ -o rebuilt-prefs.apk

# Align for performance
zipalign -v 4 rebuilt-prefs.apk aligned-prefs.apk

# Sign with debug keystore
apksigner sign --ks ~/.android/debug.keystore \
  --ks-pass pass:android aligned-prefs.apk

# Install on the emulator
adb install -r aligned-prefs.apk
```

**If `zipalign` or `apksigner` is not found:**

```bash
export PATH=$PATH:$ANDROID_HOME/build-tools/$(ls $ANDROID_HOME/build-tools/ | tail -1)
```

**If `~/.android/debug.keystore` does not exist:**

```bash
keytool -genkey -v -keystore ~/.android/debug.keystore \
  -alias androiddebugkey -keyalg RSA -keysize 2048 -validity 10000 \
  -storepass android -keypass android \
  -dname 'CN=Android Debug'
```

**If `apktool b` fails,** the error is almost always a smali syntax problem: wrong register count, missing semicolon in a type descriptor, or a broken label reference. Read the error message -- apktool reports the exact file and line.

---

## Step 6: Launch and Capture the Token

```bash
# Launch the app (replace with the actual package and activity)
adb shell am start -n <package>/<launcher_activity>

# In another terminal, watch for your hook output
adb logcat -s HookEngine
```

When the app reads the token from SharedPreferences, your hook fires and the value appears in logcat. That is the secret token -- captured through bytecode instrumentation.

Expected output:

```text
D HookEngine: auth_token
D HookEngine: s3cr3t-t0k3n-v4lu3
```

(The exact strings depend on the target app.)

---

## Step 7 (Bonus): Replace the Return Value

Now write a second hook that makes the app authenticate without knowing the real token. Use **return value replacement** -- after `getString()` returns the stored value, overwrite the register before the app's comparison logic runs:

```smali
# After move-result-object v5:
const-string v5, "THE_CORRECT_TOKEN"
# v5 now contains the correct token -- the comparison will succeed
```

If the app compares the stored token against a hardcoded expected value, you can also intercept the comparison itself. Find the `invoke-virtual` that calls `String.equals()` and force it to return `true`:

```smali
# Instead of letting equals() run, force the result
const/4 v0, 0x1
# Then skip the original invoke-virtual/equals and move-result
```

Multiple approaches work. The point is that you control the data flow at the bytecode level.

Rebuild, reinstall, and verify the app shows "Authenticated" without your knowing the real token.

---

## Deliverables

| Artifact | Description |
|----------|-------------|
| Hooked smali file | Before-and-after diff showing your inserted lines |
| Logcat output | `HookEngine` tag showing the intercepted key and value |
| Aligned APK | `aligned-prefs.apk` -- the rebuilt, signed APK |
| Bonus screenshot | App showing "Authenticated" with return-value hook active |

---

## Success Criteria

- [ ] `SharedPreferences.getString()` call-site correctly identified in smali with file path and register numbers
- [ ] `.locals` bumped to accommodate the scratch register
- [ ] `Log.d()` hook inserted after `move-result-object` without crashing the app
- [ ] Logcat shows the intercepted token value under the `HookEngine` tag
- [ ] Bonus: app authenticates with your forged return value

---

## Self-Check Script

```bash
#!/usr/bin/env bash
echo "=========================================="
echo "  LAB 7: MANUAL SMALI HOOKING SELF-CHECK"
echo "=========================================="
PASS=0; FAIL=0

# Check that the hooked APK is built
if [ -f aligned-prefs.apk ]; then
  echo "  [PASS] Hooked APK built (aligned-prefs.apk)"
  ((PASS++))
else
  echo "  [FAIL] aligned-prefs.apk not found"
  ((FAIL++))
fi

# Check that the APK installs
PKG=$(adb shell pm list packages 2>/dev/null | grep -i "sharedprefs\|prefs\|biometric" | head -1)
if [ -n "$PKG" ]; then
  echo "  [PASS] App installed: $PKG"
  ((PASS++))
else
  echo "  [WARN] Could not confirm package installed -- check package name"
fi

# Check for HookEngine log tag output (proves hook fired)
HOOK_LINES=$(adb logcat -d -s HookEngine 2>/dev/null | grep -c ".")
echo "  HookEngine log lines: $HOOK_LINES"
if [ "$HOOK_LINES" -gt 0 ]; then
  echo "  [PASS] Hook fired -- data captured in logcat"
  ((PASS++))
else
  echo "  [FAIL] No HookEngine output in logcat"
  ((FAIL++))
fi

# Check that the smali modification exists in the decoded dir
if [ -d decoded-prefs/ ]; then
  HOOK_FOUND=$(grep -rn "HookEngine" decoded-prefs/smali*/ 2>/dev/null | grep -c "Log")
  if [ "$HOOK_FOUND" -gt 0 ]; then
    echo "  [PASS] Log.d hook found in smali ($HOOK_FOUND occurrence(s))"
    ((PASS++))
  else
    echo "  [FAIL] No Log.d(\"HookEngine\"...) found in decoded smali"
    ((FAIL++))
  fi
else
  echo "  [SKIP] decoded-prefs/ directory not found"
fi

# Check .locals was bumped
if [ -d decoded-prefs/ ]; then
  LOCALS=$(grep -rn "\.locals" decoded-prefs/smali*/ 2>/dev/null | head -5)
  echo "  [INFO] .locals declarations (verify bump): review manually"
fi

echo ""
echo "  Results: $PASS passed, $FAIL failed"
echo ""
echo "  Manual checks:"
echo "    1. Review logcat output -- confirm the SharedPreferences key and value are logged"
echo "    2. Verify the token value is visible in the HookEngine tag output"
echo "    3. Bonus: confirm Authenticated state if return-value hook is applied"
echo "=========================================="
[ "$FAIL" -eq 0 ] && echo "  Lab 7 COMPLETE." || echo "  Lab 7 INCOMPLETE -- review failed checks."
```

---

## What You Just Demonstrated

You wrote your first raw smali hook. Two lines of insertion -- a `const-string` and an `invoke-static` -- were enough to intercept a runtime value that was invisible from the UI, invisible from the resources, and invisible from static analysis. The app computed the token, stored it, read it back, and your hook captured it in transit.

This is the foundation of all bytecode instrumentation. The patch-tool does the same thing -- it just automates the search-and-insert for known API signatures. For unknown APIs, custom SDKs, and one-off interception needs, you do it by hand. The methodology is always the same: find the call, insert after the result capture, do what you need with the data.

You now have the skill to hook any method call in any APK. The only variable is finding the right call-site -- and that is a grep away.
