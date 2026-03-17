---
title: "Smali Fundamentals"
description: "The language of Android bytecode — reading, writing, and editing smali for hook development"
---

Everything up to this point has been about operating. You ran the patch-tool, pushed payloads, walked through target flows, and collected evidence. The tool did the bytecode work. You never needed to see what happened inside the smali, because the existing hooks covered every standard camera, location, and sensor API path.

That ends now.

> **Skills Checkpoint:** This chapter marks the transition from *operating* the toolkit to *extending* it. Chapters 13 and 14 require a different skill set than Chapters 5 through 12. You need comfort reading structured text files, making precise single-line edits, and reasoning about data flow through code you did not write. Chapter 14 additionally requires basic programming ability in Kotlin. If you are primarily an operator and do not plan to write custom hooks, Chapter 12 is a natural stopping point. Everything that follows is for practitioners who want to build new capabilities, not just use existing ones.

The remaining chapters teach you to build your own weapons. When you encounter a target that uses a non-standard API -- a custom camera wrapper, a proprietary location SDK, an encrypted SharedPreferences store -- the built-in hooks will not cover it. You need to open the smali, find the method you want to intercept, and write the two to five lines of injection code that splice your logic into the target's execution flow.

This is not as hard as it sounds. You do not need to become a smali expert. You do not need to understand the Dalvik instruction set architecture. You need to recognize five patterns, understand how registers work, and know where to insert your code. That is it. Five patterns, a handful of instructions, and the confidence to edit a text file.

Think of it this way: you are not rewriting the building's electrical system. You are splicing into one wire.

---

## Smali in 60 Seconds

When you write Java or Kotlin, the compiler turns your source code into low-level instructions that the Android runtime (Dalvik/ART) can execute. These instructions are stored in `.dex` files inside the APK. You cannot get the original Java back from a `.dex` file, but you *can* convert it to smali -- a text format where each instruction is on its own line, readable and editable. Think of smali as assembly language for Android apps.

Smali is the human-readable representation of Android's Dalvik bytecode. When `apktool` decodes an APK, it converts the compiled `.dex` files into `.smali` text files -- one file per Java/Kotlin class. The directory structure mirrors the package hierarchy: `com/example/app/MainActivity.smali`.

Every `.java` or `.kt` file in the original source compiles to one or more `.smali` files. You cannot recover the original source from smali (that is what jadx is for, and it is lossy). But you can read smali well enough to find methods, understand their signatures, and insert hook code at precise locations.

---

## Anatomy of a Smali File

Here is a real method from a decoded APK. Every line matters:

```smali
.class public Lcom/example/app/MainActivity;
.super Landroidx/appcompat/app/AppCompatActivity;

.method public onCreate(Landroid/os/Bundle;)V
    .registers 4

    invoke-super {p0, p1}, Landroidx/appcompat/app/AppCompatActivity;->onCreate(Landroid/os/Bundle;)V

    const/high16 v0, 0x7f0b0000
    invoke-virtual {p0, v0}, Lcom/example/app/MainActivity;->setContentView(I)V

    return-void
.end method
```

Breaking it down:

### Class declaration
```smali
.class public Lcom/example/app/MainActivity;
```
The `L` prefix and `;` suffix are smali's type notation. `Lcom/example/app/MainActivity;` = `com.example.app.MainActivity` in Java. Every class reference in smali uses this L-notation with slashes instead of dots.

### Method signature
```smali
.method public onCreate(Landroid/os/Bundle;)V
```
- `public` -- access modifier
- `onCreate` -- method name
- `(Landroid/os/Bundle;)` -- parameter types (one Bundle)
- `V` -- return type (void)

### Registers
```smali
.registers 4
```
Smali uses numbered registers instead of named variables. There are two kinds:
- **`p` registers** -- parameters. `p0` = `this` (for instance methods), `p1` = first parameter, `p2` = second, etc.
- **`v` registers** -- local variables. `v0`, `v1`, `v2`, etc.

The `.registers N` declaration says how many total registers exist (locals + params). Alternatively, `.locals N` declares only the local registers (params are additional and do not count).

Example: `.registers 4` in a method with signature `(Landroid/os/Bundle;)V`:
```text
v0, v1     = local variables (yours to use)
p0 = v2    = 'this' (the object the method is called on)
p1 = v3    = first parameter (the Bundle)
Total: 2 locals + 2 params = 4 registers
```

**This matters for hooking** because when you insert code, you might need a scratch register. If all registers are in use, you will need to bump the count.

### Method calls
```smali
invoke-virtual {p0, v0}, Lcom/example/app/MainActivity;->setContentView(I)V
```
- `invoke-virtual` -- call an instance method
- `{p0, v0}` -- arguments: `this` and the layout resource ID
- `Lcom/example/app/MainActivity;->setContentView(I)V` -- target: class, method name, parameter types, return type

The four invoke variants you will see:

| Instruction | When |
|-------------|------|
| `invoke-virtual` | Normal instance method call |
| `invoke-static` | Static method call (no `this`) |
| `invoke-interface` | Method on an interface reference |
| `invoke-direct` | Constructor or private method |

### Capturing return values
```smali
invoke-virtual {v3}, Landroid/location/LocationManager;->getLastKnownLocation(Ljava/lang/String;)Landroid/location/Location;
move-result-object v4
```
After any `invoke-*` that returns a value, the next instruction captures it:
- `move-result-object vN` -- capture an object return value
- `move-result vN` -- capture a primitive (int, boolean, etc.)

### Return statements
```smali
return-void        # method returns nothing
return-object v1   # method returns an object in v1
return v0          # method returns a primitive in v0
```

---

## The Five Things You Need to Recognize

When you are editing smali to insert hooks, you need to spot exactly five things:

1. **Method boundaries** -- `.method` / `.end method` -- where a method starts and ends
2. **Register declarations** -- `.registers N` or `.locals N` -- how many registers exist
3. **Method invocations** -- `invoke-*` -- where methods are called
4. **Return values** -- `move-result-object` / `move-result` -- where return values are captured
5. **Parameter registers** -- `p0`, `p1`, `p2` -- where input data lives

That is it. You do not need to understand arithmetic instructions, conditional branches, exception handlers, or annotation blocks. You need these five things, and you are ready to write hooks.

---

## Type Notation Quick Reference

| Java Type | Smali Notation |
|-----------|---------------|
| `int` | `I` |
| `boolean` | `Z` |
| `long` | `J` |
| `float` | `F` |
| `double` | `D` |
| `void` | `V` |
| `byte` | `B` |
| `String` | `Ljava/lang/String;` |
| `int[]` | `[I` |
| `Object` | `Ljava/lang/Object;` |
| `com.example.Foo` | `Lcom/example/Foo;` |

---

## The Three Hook Patterns

**Which pattern do you need?**
```text
Where is the data you want to intercept?
  -> Arrives as a method PARAMETER (e.g., analyze(ImageProxy))     -> Pattern 1: Method Entry
  -> Comes from a method CALL inside the body (e.g., getLastKnownLocation())  -> Pattern 2: Call-Site
  -> Is RETURNED by this method (e.g., toBitmap())                 -> Pattern 3: Return Value
```

Every hook you will ever write falls into one of three patterns. Each one is two lines of smali.

### Pattern 1: Method Entry Injection

Insert code at the top of a method, right after `.registers`/`.locals`. Used when you want to replace or modify a parameter before the method body runs.

**Example A -- Camera analysis interception:**

```smali
# BEFORE (original)
.method public analyze(Landroidx/camera/core/ImageProxy;)V
    .registers 4
    # ... app's original code uses p1 (the ImageProxy)

# AFTER (hooked)
.method public analyze(Landroidx/camera/core/ImageProxy;)V
    .registers 4
    invoke-static {p1}, Lcom/hookengine/core/FrameInterceptor;->intercept(Landroidx/camera/core/ImageProxy;)Landroidx/camera/core/ImageProxy;
    move-result-object p1
    # ... app's original code now uses the FAKE ImageProxy in p1
```

Two lines. That is the entire camera hook for the analysis pipeline. `p1` is the ImageProxy parameter. You call your interceptor with the real one, get a `FakeImageProxy` back, and overwrite `p1`. The rest of the method runs on fake data without knowing anything changed.

> **Reading the long line:** In actual smali, this must be one line. Here it is broken down for clarity:
> `invoke-static {p1},` -- call a static method, passing p1 as the argument
> `Lcom/hookengine/core/FrameInterceptor;` -- on the FrameInterceptor class
> `->intercept(Landroidx/camera/core/ImageProxy;)` -- method name and parameter type
> `Landroidx/camera/core/ImageProxy;` -- returns an ImageProxy

**Example B -- SharedPreferences value interception:**

Suppose the target stores authentication tokens in SharedPreferences and retrieves them in a method that takes a `SharedPreferences` object as a parameter. You want to log every value fetched:

```smali
# BEFORE (original)
.method public loadAuthConfig(Landroid/content/SharedPreferences;)V
    .locals 3
    # ... reads tokens from p1

# AFTER (hooked)
.method public loadAuthConfig(Landroid/content/SharedPreferences;)V
    .locals 3
    const-string v0, "HookEngine"
    const-string v1, "SharedPreferences accessed in loadAuthConfig"
    invoke-static {v0, v1}, Landroid/util/Log;->d(Ljava/lang/String;Ljava/lang/String;)I
    # ... reads tokens from p1 (original code continues)
```

Here we insert a log statement right at method entry. We already have v0 and v1 available as locals. The hook fires every time the method is called, telling you via logcat that the app accessed its preference store. This is a reconnaissance hook -- you are not modifying data, you are watching the access pattern.

**Use case:** Intercept incoming data -- ImageProxy, Location, SensorEvent. Log method entry for reconnaissance.

### Pattern 2: Call-Site Interception

Find a specific method call inside a method and insert code after it to modify the return value.

**Example A -- Location spoofing:**

```smali
# BEFORE (original)
invoke-virtual {v3}, Landroid/location/LocationManager;->getLastKnownLocation(Ljava/lang/String;)Landroid/location/Location;
move-result-object v4
# app uses v4 (the real Location)

# AFTER (hooked)
invoke-virtual {v3}, Landroid/location/LocationManager;->getLastKnownLocation(Ljava/lang/String;)Landroid/location/Location;
move-result-object v4
invoke-static {v4}, Lcom/hookengine/core/LocationInterceptor;->interceptLocation(Landroid/location/Location;)Landroid/location/Location;
move-result-object v4
# app uses v4 (now the FAKE Location)
```

Find the call, insert two lines after the `move-result-object`. The original return value goes in, the fake comes out. The variable register (`v4`) now holds your data.

**Example B -- WebView URL logging:**

You want to log every URL the app loads in a WebView. The `loadUrl` call is your target:

```smali
# BEFORE (original)
invoke-virtual {v2, v5}, Landroid/webkit/WebView;->loadUrl(Ljava/lang/String;)V
# execution continues

# AFTER (hooked -- insert BEFORE the loadUrl call)
const-string v0, "HookEngine"
invoke-static {v0, v5}, Landroid/util/Log;->d(Ljava/lang/String;Ljava/lang/String;)I
invoke-virtual {v2, v5}, Landroid/webkit/WebView;->loadUrl(Ljava/lang/String;)V
# execution continues
```

This is a slight variation of call-site interception: instead of modifying the return value, you log the input parameter (`v5`, the URL string) right before the call. Every time the app loads a URL, your hook writes it to logcat. You see every web endpoint the app contacts, every redirect it follows, every OAuth callback it processes.

**Example C -- Network response modification:**

Intercept a response body parsed from a network call. Suppose the app reads a response string from an `InputStream`:

```smali
# BEFORE (original)
invoke-virtual {v3}, Ljava/io/BufferedReader;->readLine()Ljava/lang/String;
move-result-object v4
# app uses v4 (the response line)

# AFTER (hooked)
invoke-virtual {v3}, Ljava/io/BufferedReader;->readLine()Ljava/lang/String;
move-result-object v4
const-string v0, "HookEngine"
invoke-static {v0, v4}, Landroid/util/Log;->d(Ljava/lang/String;Ljava/lang/String;)I
# app uses v4 (logged, then continues normally)
```

This logs every line of the server response. For modification rather than logging, you would route `v4` through a static method that returns a modified string and write the result back into `v4` -- the same two-line pattern as the location hook.

**Use case:** Modify return values of system API calls -- `getLastKnownLocation`, `getString`, `isMock`. Log parameters of outgoing calls -- `loadUrl`, `openConnection`, `write`.

### Pattern 3: Return Value Replacement

Intercept the value just before a method returns it.

**Example A -- Bitmap replacement:**

```smali
# BEFORE (original)
    invoke-virtual {v0}, Landroidx/camera/core/ImageProxy;->toBitmap()Landroid/graphics/Bitmap;
    move-result-object v1
    return-object v1

# AFTER (hooked)
    invoke-virtual {v0}, Landroidx/camera/core/ImageProxy;->toBitmap()Landroid/graphics/Bitmap;
    move-result-object v1
    invoke-static {v1}, Lcom/hookengine/core/FrameInterceptor;->transform(Landroid/graphics/Bitmap;)Landroid/graphics/Bitmap;
    move-result-object v1
    return-object v1
```

Insert right before `return-object`. Transform the result. Return the fake.

**Example B -- SharedPreferences getString interception:**

The app calls `SharedPreferences.getString()` and returns the value from a wrapper method. You want to log the value before it leaves the method:

```smali
# BEFORE (original)
.method public getAuthToken()Ljava/lang/String;
    .locals 3
    iget-object v0, p0, Lcom/target/app/Config;->prefs:Landroid/content/SharedPreferences;
    const-string v1, "auth_token"
    const-string v2, ""
    invoke-interface {v0, v1, v2}, Landroid/content/SharedPreferences;->getString(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;
    move-result-object v0
    return-object v0
.end method

# AFTER (hooked)
.method public getAuthToken()Ljava/lang/String;
    .locals 3
    iget-object v0, p0, Lcom/target/app/Config;->prefs:Landroid/content/SharedPreferences;
    const-string v1, "auth_token"
    const-string v2, ""
    invoke-interface {v0, v1, v2}, Landroid/content/SharedPreferences;->getString(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;
    move-result-object v0
    const-string v1, "HookEngine"
    invoke-static {v1, v0}, Landroid/util/Log;->d(Ljava/lang/String;Ljava/lang/String;)I
    return-object v0
.end method
```

Right before the method returns the token, you log it. The token value appears in logcat. You can reuse `v1` because the previous `const-string v1, "auth_token"` is no longer needed at that point in the execution -- the `getString` call already consumed it.

**Use case:** Intercept computed results -- `toBitmap()`, processed images, calculated values, authentication tokens, configuration strings.

---

## Register Safety

The most common mistake when writing smali hooks is using a register that does not exist or is already occupied.

**Rules:**
- Never use a register number higher than what `.registers` or `.locals` declares
- If you need a scratch register, increase `.registers` by 1 and use the new slot
- **Warning:** if using `.registers` (not `.locals`), incrementing it shifts the parameter registers. If `.locals` is used instead, adding to `.locals` is safer -- params do not shift
- When in doubt, use a parameter register you just overwrote (e.g., `p1` after you have already replaced it with your fake)

> **Danger example:**
> BEFORE: `.registers 3` in a method with `(Landroid/os/Bundle;)V` -> `v0`=local, `p0`=`v1`=this, `p1`=`v2`=Bundle
> AFTER bumping to `.registers 4` -> `v0,v1`=locals, `p0`=`v2`=this, `p1`=`v3`=Bundle -- now `p0` and `p1` point to DIFFERENT internal registers! Existing code using `v1` to mean `this` is broken. **Always use `.locals` instead.**

**Example -- adding a scratch register:**
```smali
# BEFORE
.method public doSomething()V
    .locals 2
    # v0, v1 = locals. p0 = this.

# AFTER (need v2 as scratch -- bump .locals by 1)
.method public doSomething()V
    .locals 3
    # v0, v1, v2 = locals. p0 = this. Parameter registers are unaffected.
```

> **Always bump `.locals`, not `.registers`.** Incrementing `.registers` shifts parameter register assignments (p0, p1, etc.) and silently breaks existing code. Incrementing `.locals` only adds local variable slots -- parameter registers stay where they are.

---

## Finding Hook Targets in Decoded APKs

```bash
# Find all classes implementing a specific interface
grep -r "implements Landroidx/camera/core/ImageAnalysis\$Analyzer;" decoded/smali*/

# Find all calls to a specific method
grep -rn "invoke-virtual.*getLastKnownLocation" decoded/smali*/

# Find all onSensorChanged implementations
grep -rn "\.method.*onSensorChanged" decoded/smali*/

# Find method boundaries (to understand the full method context)
grep -n "\.method\|\.end method\|\.registers\|\.locals" decoded/smali/com/example/TargetClass.smali

# Find all SharedPreferences.getString calls
grep -rn "invoke-interface.*SharedPreferences;->getString" decoded/smali*/

# Find all WebView.loadUrl calls
grep -rn "invoke-virtual.*WebView;->loadUrl" decoded/smali*/

# Find all HttpURLConnection usage
grep -rn "invoke-virtual.*HttpURLConnection;->getInputStream" decoded/smali*/
```

---

## Rebuilding After Manual Edits

When you edit smali files directly (outside the patch-tool), you need to rebuild manually:

```bash
# Rebuild the APK from decoded smali
apktool b decoded/ -o rebuilt.apk

# Align (required for Android to accept the APK)
zipalign -v 4 rebuilt.apk aligned.apk

# Sign with your debug keystore
apksigner sign --ks ~/.android/debug.keystore --ks-pass pass:android aligned.apk

# Install
adb install -r aligned.apk
```

> The patch-tool handles alignment and signing automatically. When you edit smali files by hand (bypassing the patch-tool), you must do these steps yourself. Android requires APKs to be zip-aligned (for memory-mapping performance) and signed (to verify integrity).

---

## Debugging Smali Errors

If your patched APK crashes:

**`VerifyError`** -- Your smali has a type mismatch or register error. The Dalvik verifier checks every instruction at install time. Common causes:
- Used a register that does not exist (number too high)
- Wrong type in an invoke (passed an int where an object was expected)
- Missing `move-result-object` after an invoke that returns a value

**`ClassNotFoundException`** -- Your hook calls a class that is not in the APK. If you are calling into `FrameInterceptor` or `LocationInterceptor`, make sure the hook-core runtime was injected (it needs to be in one of the `smali_classesN/` directories).

**`AbstractMethodError`** -- The method signature in your invoke does not match the actual method. Check the exact parameter types and return type.

Add `Log.d()` calls to trace execution:
```smali
const-string v0, "HookDebug"
const-string v1, "Hook reached this point"
invoke-static {v0, v1}, Landroid/util/Log;->d(Ljava/lang/String;Ljava/lang/String;)I
```

---

## Common Obfuscation Patterns

Most production Android apps run ProGuard or R8 before release. Understanding what the obfuscator does -- and does not do -- is the difference between staring at incomprehensible smali and reading it fluently.

### What ProGuard/R8 Changes

**Class names** get renamed to short identifiers. `com.bank.app.security.FaceVerificationManager` becomes `com.bank.app.a.b` or even just `a.b.c.d`. The package hierarchy may be flattened or repackaged entirely. A class you expect to find at `com/bank/app/security/FaceVerificationManager.smali` now lives at `a/b.smali`.

**Method names** on application classes get shortened. `verifyFaceWithServer()` becomes `a()`. `extractBiometricTemplate()` becomes `b()`. Overloaded methods with different parameter types may all be named `a()` -- only their signatures distinguish them.

**Field names** follow the same pattern. `private String authenticationToken` becomes `private String a`. `private int retryCount` becomes `private int b`.

**String literals** are usually preserved. ProGuard does not encrypt strings by default. Log messages, error strings, URL patterns, SharedPreferences keys -- these survive obfuscation intact. They are your primary navigation aid in obfuscated code.

### What ProGuard/R8 Never Changes

**Android framework API calls.** This is the critical insight for hook authors. `invoke-virtual {v2, v5}, Landroid/webkit/WebView;->loadUrl(Ljava/lang/String;)V` is exactly the same in an obfuscated APK as in an unobfuscated one. Android's SDK classes and methods are public API -- renaming them would break the app. Every hook that targets a framework method signature works identically on obfuscated and unobfuscated targets.

**Interface implementations.** If a class implements `ImageAnalysis.Analyzer`, the `analyze(Landroidx/camera/core/ImageProxy;)V` method retains its name and signature. Interface methods defined by libraries cannot be renamed because the framework calls them by their original name.

**Library method signatures.** Third-party library APIs embedded in the APK (like CameraX, Google Play Services, or OkHttp) are also not obfuscated if they are consumed as interfaces or invoked from framework callbacks.

### Working Around Obfuscation

**Match on framework API signatures, not app class names.** Instead of searching for `grep -rn "FaceVerifier" decoded/smali*/`, search for `grep -rn "invoke-interface.*ImageAnalysis\$Analyzer" decoded/smali*/`. The framework signature is your anchor.

**Use jadx to reconstruct context.** Open the APK in jadx and let it decompile to approximate Java. Even though the decompilation is imperfect, jadx applies heuristic renaming and cross-reference analysis that makes obfuscated code more navigable. Find the method you care about in jadx, note the obfuscated class and method name, then locate it in the decoded smali.

**Search by method signature structure.** If you are looking for a method that takes a `String` and returns a `boolean` (a common pattern for validation checks), search the smali for that shape: `grep -rn "\.method.*\(Ljava/lang/String;\)Z" decoded/smali*/`. The method name might be `a()`, but the signature structure reveals its likely purpose.

**Follow string constants.** Find a unique string in the decompiled code -- a URL, an error message, a preference key -- and grep for it in the smali. The class that references that string is your target, regardless of what ProGuard named it.

**Check the mapping file.** Some APKs ship with a `proguard/mapping.txt` or `r8/mapping.txt` in the APK's assets or metadata. This file maps obfuscated names back to their originals. It is rare in production builds, but worth checking: `unzip -l target.apk | grep -i mapping`.

---

## Smali Reading Lab

The following five exercises build your smali reading skills progressively. Each exercise uses a realistic smali snippet. Work through them in order. Do not skip ahead -- each one builds on skills from the previous.

### Exercise 1: Identify Class Structure

Read the following smali and answer: What is the class name (in Java notation)? What is its superclass? List every method signature.

```smali
.class public Lcom/target/kyc/BiometricVerifier;
.super Ljava/lang/Object;
.implements Landroidx/camera/core/ImageAnalysis$Analyzer;

.method public constructor <init>()V
    .locals 1
    invoke-direct {p0}, Ljava/lang/Object;-><init>()V
    return-void
.end method

.method public analyze(Landroidx/camera/core/ImageProxy;)V
    .locals 3
    invoke-interface {p1}, Landroidx/camera/core/ImageProxy;->getImage()Landroid/media/Image;
    move-result-object v0
    invoke-virtual {p0, v0}, Lcom/target/kyc/BiometricVerifier;->processFrame(Landroid/media/Image;)V
    invoke-interface {p1}, Landroidx/camera/core/ImageProxy;->close()V
    return-void
.end method

.method private processFrame(Landroid/media/Image;)V
    .locals 2
    return-void
.end method

.method public getStatus()Ljava/lang/String;
    .locals 1
    const-string v0, "ready"
    return-object v0
.end method
```

**What to identify:**
- Class: `com.target.kyc.BiometricVerifier`
- Superclass: `java.lang.Object`
- Implements: `ImageAnalysis.Analyzer`
- Methods: `<init>()V`, `analyze(ImageProxy)V`, `processFrame(Image)V`, `getStatus()String`
- Access levels: constructor is public, `processFrame` is private, the rest are public

This is the starting point for any hook operation: understand the class you are looking at before you touch anything.

### Exercise 2: Trace Register Flow

Read this method and trace the value in each register at every step:

```smali
.method public buildPayload(Ljava/lang/String;I)Ljava/lang/String;
    .locals 2

    new-instance v0, Ljava/lang/StringBuilder;
    invoke-direct {v0}, Ljava/lang/StringBuilder;-><init>()V

    const-string v1, "token="
    invoke-virtual {v0, v1}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;

    invoke-virtual {v0, p1}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;

    const-string v1, "&code="
    invoke-virtual {v0, v1}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;

    invoke-virtual {v0, p2}, Ljava/lang/StringBuilder;->append(I)Ljava/lang/StringBuilder;

    invoke-virtual {v0}, Ljava/lang/StringBuilder;->toString()Ljava/lang/String;
    move-result-object v1

    return-object v1
.end method
```

**Trace it line by line:**
- `.locals 2` -- two local registers (v0, v1). p0 = this, p1 = String param, p2 = int param.
- `new-instance v0` -- v0 = new StringBuilder
- `invoke-direct {v0}` -- calls StringBuilder constructor on v0
- `const-string v1, "token="` -- v1 = "token="
- `append(v0, v1)` -- appends "token=" to the StringBuilder
- `append(v0, p1)` -- appends the String parameter (the token)
- `const-string v1, "&code="` -- v1 is reused, now holds "&code="
- `append(v0, v1)` -- appends "&code="
- `append(v0, p2)` -- appends the int parameter (the code)
- `toString()` on v0, result into v1 -- v1 = "token=<p1>&code=<p2>"
- Returns v1

The method builds a URL query string. Notice how v1 is reused three times -- it holds "token=", then "&code=", then the final string. Registers are cheap scratch space, not named variables.

### Exercise 3: Find the Hook Insertion Point

The following method retrieves the device location. Where would you insert a call-site hook to replace the location with a fake one? Identify the exact line number (counting from the `.method` line).

```smali
.method public checkLocation()V
    .locals 4
    iget-object v0, p0, Lcom/target/app/LocationChecker;->locationManager:Landroid/location/LocationManager;
    const-string v1, "gps"
    invoke-virtual {v0, v1}, Landroid/location/LocationManager;->getLastKnownLocation(Ljava/lang/String;)Landroid/location/Location;
    move-result-object v2
    if-eqz v2, :cond_null
    invoke-virtual {v2}, Landroid/location/Location;->getLatitude()D
    move-result-wide v0
    invoke-virtual {p0, v0, v1}, Lcom/target/app/LocationChecker;->validateCoords(DD)V
    return-void
    :cond_null
    return-void
.end method
```

**Answer:** The hook goes after line 5 (`move-result-object v2`). That is where the real Location lands in v2. Insert your two-line hook right after it:

```smali
    invoke-static {v2}, Lcom/hookengine/core/LocationInterceptor;->interceptLocation(Landroid/location/Location;)Landroid/location/Location;
    move-result-object v2
```

Now v2 holds the fake Location, and the `getLatitude()` call on line 7 reads your coordinates instead of the real ones. Notice that you do not need a scratch register -- you reuse v2, the same register the original code was already using.

### Exercise 4: Register Calculation

This method uses `.registers` instead of `.locals`. Determine the register layout and explain what would happen if you incremented `.registers` by 1 to get a scratch register.

```smali
.method public onResult(Ljava/lang/String;Z)V
    .registers 5
    const-string v0, "ResultHandler"
    invoke-static {v0, p1}, Landroid/util/Log;->d(Ljava/lang/String;Ljava/lang/String;)I
    if-eqz p2, :cond_false
    invoke-virtual {p0, p1}, Lcom/target/app/Handler;->processSuccess(Ljava/lang/String;)V
    :cond_false
    return-void
.end method
```

**Analysis:**
- Method signature: `(Ljava/lang/String;Z)V` -- takes String and boolean, returns void
- Instance method, so p0 = this. Three parameter registers: p0, p1 (String), p2 (boolean)
- `.registers 5` = 5 total = 2 locals + 3 params
- Register mapping: v0 = local, v1 = local, p0 = v2 = this, p1 = v3 = String, p2 = v4 = boolean

**If you bump to `.registers 6`:**
- Now: v0, v1, v2 = locals. p0 = v3 = this, p1 = v4 = String, p2 = v5 = boolean
- **Problem:** The existing `const-string v0` is fine (still a local), but `invoke-static {v0, p1}` now refers to v4 instead of v3 for p1. That is still correct because `p1` is an alias. However, the `if-eqz p2` now points to v5 instead of v4. The smali assembler handles p-register aliases correctly, so the code that uses p-registers is safe -- but any code referencing v-registers that are actually parameters would break.

**The safe approach:** Change `.registers 5` to `.locals 3` (bumping from the implicit 2 locals to 3). This gives you v2 as a scratch register without shifting any parameter assignments. Or better yet, rewrite the file to use `.locals` from the start and avoid the entire class of errors.

### Exercise 5: Read Obfuscated Code

This method has been run through R8. The class and method names are meaningless. Identify what Android API it calls and what it likely does.

```smali
.class public La/b/c;
.super Ljava/lang/Object;

.method public final a(Landroid/content/Context;)Ljava/lang/String;
    .locals 3
    const-string v0, "user_prefs"
    const/4 v1, 0x0
    invoke-virtual {p1, v0, v1}, Landroid/content/Context;->getSharedPreferences(Ljava/lang/String;I)Landroid/content/SharedPreferences;
    move-result-object v0
    const-string v1, "session_token"
    const-string v2, ""
    invoke-interface {v0, v1, v2}, Landroid/content/SharedPreferences;->getString(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;
    move-result-object v0
    return-object v0
.end method
```

**Analysis:**
- Class `a.b.c` is meaningless -- ignore it
- Method `a(Context)String` -- takes a Context, returns a String
- Line 1: Gets SharedPreferences named `"user_prefs"` with mode 0 (MODE_PRIVATE)
- Line 2: Calls `getString("session_token", "")` -- reads the session token with empty default
- Returns the token value

The obfuscation renamed the class and method, but it could not rename `Context.getSharedPreferences()` or `SharedPreferences.getString()` because those are Android framework APIs. The string constants `"user_prefs"` and `"session_token"` also survived intact. This method is a session token reader. If you wanted to log every time the app reads its session token, you would insert a Pattern 3 hook right before the `return-object v0` line.

The takeaway: obfuscation hides the developer's naming choices, not the framework APIs they call. Your hooks target the framework calls, so obfuscation rarely affects them.

---

## Key Takeaways

- You need to recognize roughly ten smali instructions, not memorize 200+ opcodes
- Three hook patterns cover virtually every injection scenario
- Always bump `.locals` (not `.registers`) when you need scratch registers
- Rebuild, zipalign, sign after every manual edit
- Obfuscation changes app class and method names but never changes framework API signatures -- target the framework calls
- String literals survive obfuscation and are your best navigation tool in renamed code
- Use jadx alongside raw smali -- the decompiled Java view helps you understand the smali you need to edit

The five exercises in the Smali Reading Lab are not academic. Every skill they test -- class identification, register tracing, hook point location, register calculation, obfuscation navigation -- is something you will do on every engagement where the built-in hooks fall short. If you struggled with any of them, re-read the relevant section and try again before moving on.

**Practice:** Lab 7 (Smali Reading) puts these skills to the test with five hands-on exercises.

Next: Chapter 14 teaches you to package these manual techniques into reusable, automated hook modules that the patch-tool applies with a single command.
