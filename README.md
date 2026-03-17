# Android KYC & Biometric Security Assessment

Authorized red-team methodology to **test and harden** Android identity verification: camera feeds, GPS, sensors, and repackaged (instrumented) APK builds.

**[Read the book →](https://iamjosephmj.github.io/AndroidRedTeam/)**

A practitioner's guide to **assessing** how identity apps consume camera frames, location, motion, and integrity checks — so teams can validate defenses and fix gaps. 18 chapters, 14 hands-on labs, and a materials kit.

> **Authorized use only.** For **educational** purposes and **explicitly authorized** security assessments. Never test applications you do not have written permission to assess.
>
> **Not legal advice.** The authors provide this material **as-is**, without warranty of any kind. You are solely responsible for complying with laws in your jurisdiction. See the book’s [Rules of Engagement](https://iamjosephmj.github.io/AndroidRedTeam/book/foundations/02-rules-of-engagement/) (Chapter 2).

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

> **`patch-tool.jar` — restricted use.** The bytecode instrumentation tool in this repository is provided **exclusively** for use with the included practice targets (`materials/targets/`), apps you build yourself, or apps you have explicit written authorization to assess. Do not use it against any other application. See [LICENSE](LICENSE) for full terms.

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

## AI Agent Skills

This repo ships two knowledge files in `skills/` that give any AI coding agent the full **authorized security assessment** methodology:

| Skill | What It Does |
|-------|-------------|
| [`skills/android-red-team.md`](skills/android-red-team.md) | 41 sections of operational knowledge — recon, smali patching, injection configs, anti-tamper evasion, Kotlin patterns, a full one-pass recon script, worked hook examples, and a troubleshooting error index. |
| [`skills/android-red-team-verify.md`](skills/android-red-team-verify.md) | 8-phase post-patch verification checklist — signing, permissions, payloads, hook initialization, and evidence collection. |

Works with **Cursor**, **Windsurf**, **Cline**, **GitHub Copilot**, **Aider**, or any LLM — just load the files into your agent's context. See [Chapter 4](https://iamjosephmj.github.io/AndroidRedTeam/book/foundations/04-the-lab/) for setup instructions per agent.

## Who Is This For

Security professionals conducting **authorized** testing of Android identity verification — penetration testers, security engineers, and developers who need to **validate controls** against camera, location, sensor, and tamper weaknesses.

**No prior reverse engineering experience required.** Part I covers the foundations.

## Support

If you find this useful, consider buying me a coffee.

<a href="https://buymeacoffee.com/iamjosephmy" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-violet.png" alt="Buy Me A Coffee" height="48"></a>

## License

Code and scripts are released under the **MIT License**. Written content (book, docs) is licensed under **CC BY-NC-SA 4.0**.

All material is provided **"as is"** without warranty, for **educational** and **authorized security testing** purposes only. You are solely responsible for lawful use. See [LICENSE](LICENSE) for full terms.
