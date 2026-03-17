---
title: "Appendix B: Smali Quick Reference"
description: "Essential smali instructions, type notation, register rules, and hook pattern templates"
---

> **Usage:** Keep this open alongside your editor when writing or reviewing smali hooks. Every instruction, type descriptor, and pattern template you need is on this page.

---

## Type Notation

Every type in smali uses a single-character code (primitives) or `L`-prefixed descriptor (objects). Arrays prepend `[`.

### Primitives

| Java Type | Smali | Width | Notes |
|-----------|-------|-------|-------|
| `void` | `V` | -- | Return type only |
| `boolean` | `Z` | 1 register | `0x0` = false, `0x1` = true |
| `byte` | `B` | 1 register | |
| `short` | `S` | 1 register | |
| `char` | `C` | 1 register | |
| `int` | `I` | 1 register | |
| `long` | `J` | 2 registers | Register pair: `vN` and `vN+1` |
| `float` | `F` | 1 register | IEEE 754 hex literal |
| `double` | `D` | 2 registers | Register pair: `vN` and `vN+1` |

### Common Object Types

| Java Type | Smali Notation |
|-----------|---------------|
| `String` | `Ljava/lang/String;` |
| `Object` | `Ljava/lang/Object;` |
| `Bundle` | `Landroid/os/Bundle;` |
| `Bitmap` | `Landroid/graphics/Bitmap;` |
| `Location` | `Landroid/location/Location;` |
| `ImageProxy` | `Landroidx/camera/core/ImageProxy;` |
| `SensorEvent` | `Landroid/hardware/SensorEvent;` |
| `Context` | `Landroid/content/Context;` |
| `Intent` | `Landroid/content/Intent;` |

### Arrays

| Java Type | Smali Notation |
|-----------|---------------|
| `int[]` | `[I` |
| `byte[]` | `[B` |
| `float[]` | `[F` |
| `String[]` | `[Ljava/lang/String;` |
| `Object[]` | `[Ljava/lang/Object;` |
| `int[][]` | `[[I` |

### Reading a Full Signature

```text
Lcom/example/Foo;->process(Ljava/lang/String;IZ)Landroid/graphics/Bitmap;
```

Reads as: `com.example.Foo.process(String, int, boolean)` returning `Bitmap`.

---

## Instruction Reference

These are the instructions you will actually use when writing hooks. The full Dalvik instruction set has 200+ opcodes; you need roughly 15.

### Method Invocation

| Instruction | What It Does | Example |
|-------------|-------------|---------|
| `invoke-virtual` | Call an instance method through virtual dispatch (normal method call) | `invoke-virtual {p0, v0}, Lcom/example/Foo;->bar(I)V` |
| `invoke-static` | Call a static method (no receiver object) | `invoke-static {v1}, Lcom/hook/Intercept;->transform(Landroid/graphics/Bitmap;)Landroid/graphics/Bitmap;` |
| `invoke-interface` | Call a method on an interface reference | `invoke-interface {v0}, Landroidx/camera/core/ImageProxy;->close()V` |
| `invoke-direct` | Call a constructor (`<init>`) or private method | `invoke-direct {p0}, Ljava/lang/Object;-><init>()V` |

Arguments go in the braces. For instance methods, the first argument is the receiver (`this`). For static methods, all arguments are explicit parameters.

### Return Value Capture

| Instruction | What It Does | Example |
|-------------|-------------|---------|
| `move-result-object vN` | Capture an object returned by the preceding `invoke-*` | `move-result-object v4` |
| `move-result vN` | Capture a primitive (int, boolean, float) returned by the preceding `invoke-*` | `move-result v0` |

Must appear immediately after the `invoke-*` instruction. Omitting this when the return value is needed causes a `VerifyError`.

### Constants

| Instruction | What It Does | Example |
|-------------|-------------|---------|
| `const-string vN, "text"` | Load a string literal into a register | `const-string v0, "HookDebug"` |
| `const/4 vN, 0xH` | Load a 4-bit signed int (-8 to 7) | `const/4 v0, 0x1` (boolean true) |
| `const/16 vN, 0xHHHH` | Load a 16-bit signed int | `const/16 v0, 0x00ff` |
| `const/high16 vN, 0xHHHH0000` | Load a 32-bit value with only high 16 bits set | `const/high16 v0, 0x7f0b0000` (resource ID) |

### Return

| Instruction | What It Does | Example |
|-------------|-------------|---------|
| `return-void` | Return from a void method | `return-void` |
| `return vN` | Return a primitive value | `return v0` |
| `return-object vN` | Return an object reference | `return-object v1` |

### Control Flow

| Instruction | What It Does | Example |
|-------------|-------------|---------|
| `if-eqz vN, :label` | Branch to `:label` if `vN == 0` (or null) | `if-eqz v0, :skip_hook` |
| `if-nez vN, :label` | Branch to `:label` if `vN != 0` (or non-null) | `if-nez v0, :has_value` |
| `goto :label` | Unconditional jump | `goto :end` |

### No-Operation

| Instruction | What It Does | Example |
|-------------|-------------|---------|
| `nop` | Do nothing (1 code unit). Used to neutralize instructions without shifting offsets | Replace `if-nez v0, :fail` with `nop` |

---

## Register Cheatsheet

### .registers vs .locals

| Directive | Declares | Parameter Registers |
|-----------|---------|-------------------|
| `.registers N` | Total register count (locals + params) | Included in `N` |
| `.locals N` | Local register count only | Added automatically on top of `N` |

**Always use `.locals` in code you write.** Bumping `.registers` shifts parameter register assignments and silently breaks existing code. Bumping `.locals` adds local slots without affecting `p0`, `p1`, etc.

### p-registers vs v-registers

In an instance method with `.locals 3` and one parameter:

```text
v0, v1, v2  = local variables (yours to use freely)
p0          = this (the receiver object)
p1          = first method parameter
```

In a static method (no `this`):

```text
v0, v1, v2  = local variables
p0          = first method parameter
p1          = second method parameter
```

### Calculating Register Numbers

Under `.registers N`, parameter registers are the last slots. For an instance method with signature `(Landroid/os/Bundle;)V` and `.registers 4`:

```text
v0 = local 0
v1 = local 1
v2 = p0 = this
v3 = p1 = Bundle parameter
```

Under `.locals N`, you do not need to calculate. `v0` through `vN-1` are locals, and `p0` through `pM` are params. The runtime handles the mapping.

### When to Bump .locals

Bump `.locals` by 1 when your injected code needs a scratch register and all existing locals are occupied. Example:

```smali
# BEFORE: .locals 2 -- v0 and v1 are in use
.method public doWork()V
    .locals 2

# AFTER: .locals 3 -- v2 is now available as scratch
.method public doWork()V
    .locals 3
    const-string v2, "HookDebug"
```

Wide types (`long`, `double`) consume two consecutive registers. If you need a wide scratch, bump `.locals` by 2.

---

## Hook Pattern Templates

Copy-paste these templates. Replace the placeholder comments with your actual class names, method signatures, and register numbers.

### Pattern 1: Method Entry Injection

Intercept a parameter before the method body runs. Used for: `analyze(ImageProxy)`, `onLocationResult(LocationResult)`, `onSensorChanged(SensorEvent)`.

```smali
.method public {METHOD_NAME}({PARAM_TYPE}){RETURN_TYPE}
    .locals {N}
    # --- HOOK START ---
    invoke-static {p1}, L{HOOK_CLASS};->{HOOK_METHOD}({PARAM_TYPE}){PARAM_TYPE}
    move-result-object p1
    # --- HOOK END ---
    # ... original method body (now operates on replaced p1) ...
.end method
```

When the hook method returns `void` instead of replacing the parameter, omit `move-result-object`:

```smali
    invoke-static {p1}, L{HOOK_CLASS};->{HOOK_METHOD}({PARAM_TYPE})V
```

### Pattern 2: Call-Site Interception

Modify the return value of a method call inside a method body. Used for: `getLastKnownLocation()`, `isFromMockProvider()`, `getString()`.

```smali
    # Original call (do not modify these two lines)
    invoke-virtual {vA}, L{TARGET_CLASS};->{TARGET_METHOD}({ARGS}){ORIG_RETURN}
    move-result-object vB

    # --- HOOK START ---
    invoke-static {vB}, L{HOOK_CLASS};->{HOOK_METHOD}({ORIG_RETURN}){ORIG_RETURN}
    move-result-object vB
    # --- HOOK END ---
```

For primitive returns, use `move-result` instead of `move-result-object`.

### Pattern 3: Return Value Replacement

Transform the value a method is about to return. Used for: `toBitmap()`, processed images, computed scores.

```smali
    # ... method body computes result into vN ...

    # --- HOOK START ---
    invoke-static {vN}, L{HOOK_CLASS};->{HOOK_METHOD}({RETURN_TYPE}){RETURN_TYPE}
    move-result-object vN
    # --- HOOK END ---

    return-object vN
.end method
```

### Bonus: Force Return (Bypass a Check)

Replace an entire method body to always return a fixed value. Used for: `isRooted()`, `isValid()`, `isMockProvider()`.

```smali
.method public {METHOD_NAME}()Z
    .locals 1
    const/4 v0, 0x1        # 0x1 = true, 0x0 = false
    return v0
.end method
```

---

## Common Errors

| Error | Cause | One-Line Fix |
|-------|-------|-------------|
| `VerifyError` | Register out of bounds, type mismatch, or missing `move-result-object` after an `invoke-*` that returns a value | Check register count in `.locals`; ensure every invoke with a non-void return is followed by the correct `move-result` variant |
| `ClassNotFoundException` | Hook calls a class not present in the APK (runtime classes not injected) | Confirm the hook-core runtime exists in one of the `smali_classesN/` directories; re-run the patch-tool if missing |
| `AbstractMethodError` | Method signature in `invoke-*` does not match the actual method (wrong parameter types or return type) | Compare your invoke signature against the real method in the decompiled smali character by character |
| `NoSuchMethodError` | Method name is misspelled or does not exist on the target class | Grep the decoded APK for the exact method name and verify the declaring class |
| `NullPointerException` in hook | The register you passed to `invoke-static` was null (e.g., the app had no data at that point) | Add a null guard: `if-eqz vN, :skip` before the hook call |

### Debugging Tip

Insert a `Log.d()` call to confirm your hook is reached:

```smali
const-string v0, "HookDebug"
const-string v1, "Hook fired"
invoke-static {v0, v1}, Landroid/util/Log;->d(Ljava/lang/String;Ljava/lang/String;)I
```

Then monitor: `adb logcat -s HookDebug`
