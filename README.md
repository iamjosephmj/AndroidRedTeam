# Android Biometric Bypass

Injecting cameras, sensors & location to defeat Android identity verification.

**[Read the book →](https://iamjosephmj.github.io/AndroidRedTeam/)**

A practitioner's guide to intercepting and controlling every data source an Android KYC app consumes — camera frames, GPS coordinates, sensor readings, and more. 18 chapters, 14 hands-on labs, and a complete materials kit.

> **This material is for authorized security testing only.** Never test applications you do not have explicit permission to assess.

---

## What's Inside

| | Description |
|---|---|
| **The Book** | 18 chapters across five parts — from threat landscape through advanced evasion to defensive countermeasures. |
| **The Labs** | 14 hands-on exercises with real APKs, concrete deliverables, and self-check scripts. Every lab maps to a book chapter. |
| **The Materials Kit** | Target APKs, payload configs, automation scripts — everything you need to run engagements. |
| **Quick Reference** | Single-page cheatsheet with every command, payload format, and troubleshooting tip. |

## Repository Structure

```
.
├── patch-tool.jar                    # Bytecode instrumentation tool
├── book/                             # Astro/Starlight documentation site
│   └── src/content/docs/
│       ├── book/                     # 18 book chapters
│       │   ├── foundations/          # Part I:  Threat landscape, Android internals, lab setup
│       │   ├── toolkit/             # Part II: Recon, injection pipeline, camera/GPS/sensors
│       │   ├── operations/          # Part III: Full engagements, reporting, scaling
│       │   ├── advanced/            # Part IV: Smali, custom hooks, anti-tamper, automation
│       │   ├── defense/             # Part V:  Blue team detection, defense-in-depth
│       │   └── appendices/          # Cheatsheet, Smali reference, target catalog
│       └── labs/                     # 14 hands-on exercises
└── materials/
    ├── targets/                      # Target APKs for labs
    │   └── target-kyc-basic.apk
    ├── payloads/
    │   ├── frames/                   # Camera frame generation
    │   ├── locations/                # GPS spoofing configs (Times Square, Shibuya, etc.)
    │   └── sensors/                  # Sensor profiles (holding, walking, tilt, nod)
    └── scripts/                      # Automation scripts (recon, batch-patch, deploy)
```

## The Methodology

Every engagement follows the same cycle:

1. **Recon** — Decode the APK, map every hookable surface
2. **Patch** — Instrument the bytecode with the patch-tool
3. **Configure** — Push payloads (frames, GPS configs, sensor profiles)
4. **Execute** — Run the target flow with all injection subsystems active
5. **Report** — Capture evidence, compute statistics, write findings

## Quick Start

### Prerequisites

- Java 11+
- Android SDK with `adb`, `apktool`, `zipalign`, `apksigner`
- An Android emulator or rooted device
- Node.js 18+ (for building the book site locally)

### Run the labs

```bash
# Verify your environment
java -jar patch-tool.jar --help
adb devices
apktool --version

# Decode the target
apktool d materials/targets/target-kyc-basic.apk -o decoded/

# Patch it
java -jar patch-tool.jar materials/targets/target-kyc-basic.apk \
  --out patched.apk --work-dir ./work
```

Follow along at [Lab 0: Environment Verification](https://iamjosephmj.github.io/AndroidRedTeam/labs/00-environment-verification/).

### Build the book locally

```bash
cd book
npm install
npm run dev
```

The site runs at `http://localhost:4321/AndroidRedTeam/`.

## Cursor Agent Skills

If you use [Cursor](https://cursor.sh/), this repo ships two Agent Skills that give the AI assistant the full red team methodology:

| Skill | What It Does |
|-------|-------------|
| `skills/android-red-team.md` | 41 sections of operational knowledge — recon, smali patching, injection configs, anti-tamper evasion, Kotlin patterns, a full one-pass recon script, worked hook examples, and a troubleshooting error index. The agent can write patches, generate configs, and diagnose failures. |
| `skills/android-red-team-verify.md` | 8-phase post-patch verification checklist. The agent systematically checks signing, permissions, payloads, hook initialization, and evidence collection. |

```bash
cp skills/android-red-team.md .cursor/skills/
cp skills/android-red-team-verify.md .cursor/skills/
```

Then ask the agent to decode, patch, or verify — it has the domain knowledge to execute end-to-end.

## Who Is This For

Security professionals conducting **authorized** testing of Android identity verification systems — penetration testers, security engineers, and developers who want to understand biometric bypass so they can defend against it.

**No prior reverse engineering experience required.** Part I covers the foundations.

## Support

If you find this useful, consider buying me a coffee.

<a href="https://buymeacoffee.com/iamjosephmy" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-violet.png" alt="Buy Me A Coffee" height="48"></a>

## License

This material is provided for educational and authorized security testing purposes.
