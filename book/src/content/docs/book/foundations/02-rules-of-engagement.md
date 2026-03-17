---
title: "Rules of Engagement"
description: "Legal frameworks, authorization boundaries, and the ethical operator's checklist"
---

On **authorized targets** — apps and devices you own or are contracted to test — the techniques in this book let you **simulate attacker capability**: substituted camera feeds, simulated GPS and motion data, and instrumented APK builds. Used correctly, they **validate whether client-side controls hold up** and produce evidence for remediation. The same techniques applied **without authorization** are not security testing; they are unauthorized access. The tooling has no opinion on scope — **you** must.

That distinction — between **authorized assessment** and unauthorized use — is what separates a security professional from an attacker. This chapter comes before the technical content because the rules come first: not as a formality, but because understanding legal and ethical boundaries is a prerequisite for practicing professionally.

If you skip this chapter, you haven't saved time. You've created risk — for yourself, your employer, your client, and the broader security community that depends on maintaining the distinction between authorized testing and unauthorized access.

---

## What Authorization Looks Like

"I have permission" is not the same as "I think it's okay." Authorization for security testing must be explicit, documented, and scoped.

### Written Scope

Before any engagement begins, you need a scope document that defines:

- **The target:** Which specific application(s) are being tested. Package names, version numbers, environments (staging vs. production).
- **The attack surfaces:** Which capabilities are in scope. Camera injection? GPS spoofing? Sensor manipulation? All three? Just one?
- **The boundaries:** What is explicitly out of scope. Backend servers? Other apps on the device? Real user data?
- **The timeline:** When testing is authorized. Start date, end date, time windows if applicable.
- **The reporting channel:** Who receives the findings. How they're communicated. What format.

A verbal "yeah, go ahead and test our app" from a developer is not authorization. It doesn't protect you legally, it doesn't set expectations for the client, and it doesn't provide a record if questions arise later. Get it in writing. Have it signed by someone with authority to authorize the testing — typically a CISO, VP of Engineering, or equivalent.

### Rules of Engagement Document

For formal engagements, the scope document expands into a Rules of Engagement (RoE) that includes:

- **Testing methodology:** What tools will be used (the patch-tool, adb, specific payload types). This prevents surprise when the client's SOC detects activity. Note that `patch-tool.jar` is provided exclusively for use with this project's practice targets, apps you build yourself, or apps covered by your engagement agreement — it must not be used against any application without proper authorization.
- **Communication protocol:** How to report findings during the engagement (immediately for critical issues, daily summary for others).
- **Escalation contacts:** Who to call if something goes wrong — if you accidentally trigger a production alert, if you discover evidence of actual fraud, if a test causes unexpected behavior.
- **Data handling:** How test data (injected frames, captured screenshots, delivery logs) will be stored, encrypted, and eventually destroyed.
- **Coordination with defenders:** Whether the client's security team knows the test is happening (white-box), knows a test will happen but not when (gray-box), or doesn't know at all (red team). This affects everything about how you operate.

### The "Lab Exception"

The exercises in this book use purpose-built practice targets — applications specifically designed to be patched and tested. This is the lab environment, and it's the one context where explicit client authorization isn't required, because you are both the tester and the target owner.

However, even in a lab environment, good habits matter. Treat every lab exercise as if it were a real engagement: document your recon, record your evidence, write your report. The habits you build in the lab are the habits you'll carry to real engagements.

---

## Legal Frameworks

This section provides awareness of the legal landscape, not legal advice. Laws vary by jurisdiction, change over time, and have nuances that require a licensed attorney to interpret for your specific situation. For any real engagement, consult legal counsel familiar with computer security law in the relevant jurisdiction.

### United States: Computer Fraud and Abuse Act (CFAA)

The CFAA (18 U.S.C. Section 1030) is the primary federal law governing unauthorized access to computer systems. The key concept is "exceeds authorized access" — accessing a computer with authorization and using that access to obtain information the accessor is not entitled to obtain.

For mobile application testing:
- Testing your own application on your own device is generally permissible
- Testing a client's application under a signed scope agreement establishes authorization
- The 2021 *Van Buren v. United States* Supreme Court decision narrowed the scope of "exceeds authorized access" but didn't eliminate it

The CFAA carries both civil and criminal penalties. Civil liability can include actual damages and profits. Criminal penalties range up to 10 years imprisonment for first offenses involving certain types of access.

### United States: DMCA Section 1201 (Anti-Circumvention)

Section 1201 of the Digital Millennium Copyright Act prohibits circumventing "technological protection measures" (TPMs) that control access to copyrighted works. This is directly relevant to the techniques in this book: APK signature verification, DEX integrity checks, and certificate pinning are all arguably TPMs. Bypassing them during security testing could technically be characterized as circumvention.

**The security research exemption (Section 1201(j))** provides a defense for circumvention performed "solely for the purpose of good-faith security research." To qualify, the research must:
- Be conducted on a lawfully acquired copy of the software
- Be performed in a controlled environment (not affecting other systems)
- Not violate any other applicable law (including the CFAA)
- The information derived from the research must not be used for purposes other than furthering security

**The triennial rulemaking process** — Every three years, the Library of Congress grants temporary exemptions to Section 1201. The 2021 and 2024 rulemaking cycles expanded protections for good-faith security research, broadening the definition to include testing performed under a reasonable belief that the findings would improve security. These exemptions are not permanent — they must be renewed at each rulemaking cycle.

**Practical impact for this book's techniques:** Decompiling an APK, patching signature verification, modifying bytecode, and re-signing the package all involve circumventing access controls. Under a formal engagement with written authorization, the security research exemption provides strong protection. Without authorization, the same actions carry real legal risk. This is one more reason why the scope document and engagement agreement described at the start of this chapter are not optional — they are part of your legal defense.

### United Kingdom: Computer Misuse Act 1990

The CMA establishes three principal offenses:

1. **Unauthorized access** (Section 1) — Knowingly causing a computer to perform any function with intent to secure unauthorized access. Maximum penalty: 2 years imprisonment.

2. **Unauthorized access with intent** (Section 2) — Unauthorized access with intent to commit or facilitate further offenses. Maximum penalty: 5 years.

3. **Unauthorized acts causing damage** (Section 3) — Unauthorized modification of computer material. Maximum penalty: 10 years.

The CMA's scope is broad — "causing a computer to perform any function" covers essentially any interaction with a system. Authorization is the defense: if you have the system owner's permission to perform the testing, the access is authorized.

### European Union

The EU's legal landscape for security testing is fragmented across member states, but two frameworks are particularly relevant:

**NIS2 Directive** — The Network and Information Security Directive requires certain organizations to implement security testing as part of their risk management. This creates a regulatory mandate for the kind of testing this book describes, but the testing must still be authorized by the organization being tested.

**Cyber Resilience Act (CRA)** — The CRA (Regulation (EU) 2024/2847, entered into force December 2024, obligations phasing in through 2027) requires manufacturers of products with digital elements — including mobile applications that process identity data — to implement cybersecurity-by-design and maintain coordinated vulnerability disclosure processes. For security testers, the CRA matters in two ways. First, it creates a regulatory expectation that products *will* be tested: manufacturers must identify and document risks, perform security testing, and provide security updates. Second, it mandates that manufacturers establish vulnerability handling processes and accept reports from external researchers. This does not give testers carte blanche — you still need authorization — but it means the manufacturer has a legal obligation to have a disclosure channel and to handle your report. If a vendor refuses to engage with a coordinated disclosure, the CRA gives the reporter more ground to stand on. The CRA applies to the product manufacturer, not to the tester directly; your obligations remain governed by local computer misuse laws and your engagement agreement.

**GDPR** — The General Data Protection Regulation has implications for biometric testing because face images and biometric templates are "special category data" under Article 9. Even in a testing context, handling biometric data requires a lawful basis. In practice, this means:
- Use synthetic or self-generated face data, not real users' biometric data
- If test results contain biometric data, handle it under your data processing agreements
- Document the lawful basis for any biometric data processing in your engagement report

### Other Jurisdictions

Many countries have similar computer misuse laws, but the details vary significantly:

- **Australia:** Criminal Code Act 1995, Part 10.7 — covers unauthorized access and modification, with penalties up to 10 years
- **Canada:** Criminal Code Section 342.1 — "unauthorized use of computer" with penalties up to 10 years
- **Singapore:** Computer Misuse Act — closely modeled on the UK CMA, with additional provisions for cybersecurity testing under the Cybersecurity Act 2018
- **Japan:** Act on Prohibition of Unauthorized Computer Access — strict liability for unauthorized access, with limited exceptions for security research

The trend globally is toward recognizing authorized security testing as legitimate, but the definitions of "authorized" and the required documentation vary. In some jurisdictions, even possessing tools designed for unauthorized access can be an offense — which makes your scope documentation all the more important.

### General Principles

Regardless of jurisdiction:

1. **Authorization is your primary defense.** Get it in writing before you start.
2. **Scope matters.** Authorization to test the mobile app doesn't extend to the backend servers unless the scope document says so.
3. **Jurisdiction follows the target.** If you're testing a UK company's app from the US, both countries' laws may apply.
4. **Documentation protects you.** Keep the authorization documents, scope agreements, and communication records indefinitely.
5. **When in doubt, get legal advice.** An hour of attorney time is cheap compared to the consequences of unauthorized access.
6. **Safe harbor programs help but don't replace scope documents.** Some companies have vulnerability disclosure policies (VDPs) that provide safe harbor for good-faith security research. These are valuable, but they typically cover discovery and reporting — not the systematic, multi-surface testing that a red team engagement entails. For the kind of comprehensive testing this book teaches, a VDP is not sufficient. You need a formal engagement agreement.

### Jurisdiction Quick Reference

| Jurisdiction | Primary Law(s) | Key Offense | Max Penalty | Security Research Exception |
|---|---|---|---|---|
| **US** | CFAA (18 U.S.C. §1030) + DMCA §1201 | Unauthorized access; circumvention of access controls | 10 years (CFAA criminal); statutory damages (DMCA) | DMCA §1201(j) security research exemption; triennial rulemaking exemptions (2021, 2024) |
| **UK** | Computer Misuse Act 1990 | Unauthorized access (§1); unauthorized access with intent (§2); unauthorized modification (§3) | 2-10 years depending on offense | No statutory exemption; authorization is the defense |
| **EU** | NIS2 Directive + CRA (2024/2847) + GDPR | Varies by member state; NIS2 mandates security testing for covered entities | Varies by member state | CRA mandates vendor vulnerability disclosure processes; GDPR requires lawful basis for biometric data |
| **Australia** | Criminal Code Act 1995, Part 10.7 | Unauthorized access and modification | 10 years | No broad statutory exemption; authorization required |
| **Canada** | Criminal Code §342.1 | Unauthorized use of computer | 10 years | No statutory exemption; authorization required |
| **Singapore** | Computer Misuse Act + Cybersecurity Act 2018 | Unauthorized access and modification | Fines + imprisonment (varies) | Cybersecurity Act 2018 provides framework for authorized testing |
| **Japan** | Act on Prohibition of Unauthorized Computer Access | Unauthorized access (strict liability) | 3 years or ¥1M fine | Limited exceptions for security research; strict interpretation |

This table is a starting point, not legal advice. Laws change, and the details matter — especially the definition of "authorization" and what constitutes "access" in each jurisdiction. For any real engagement that crosses borders, consult legal counsel familiar with both the tester's and the target's jurisdictions.

---

## Responsible Disclosure

When you find a vulnerability during authorized testing, you report it to your client through the agreed-upon channel. But what about vulnerabilities you discover incidentally — issues in third-party SDKs, framework-level bugs, or vulnerabilities in apps you encounter outside a formal engagement?

### The Coordinated Disclosure Process

1. **Document the vulnerability.** Describe what you found, how it can be reproduced, and what impact it has. Be specific enough for the vendor to reproduce it, but don't include working exploit code unless they request it.

2. **Contact the vendor.** Most companies have a security contact (`security@company.com`) or a bug bounty program. If you can't find a security contact, try their general support channel or a responsible disclosure platform like HackerOne or Bugcrowd.

3. **Set a timeline.** The standard coordinated disclosure timeline is 90 days: you give the vendor 90 days to develop and deploy a fix before you publish. Some researchers use 60 days for less complex issues. The key is communicating the timeline upfront so the vendor knows the clock is ticking.

4. **Follow up.** If the vendor doesn't respond within 7-14 days, try again through a different channel. Document your attempts.

5. **Publish (if appropriate).** After the timeline expires or the fix is deployed, you may publish your findings — with enough detail for defenders to protect themselves, but without providing a turnkey exploit for attackers. Many researchers publish a technical writeup that describes the vulnerability class and mitigation without revealing every implementation detail.

### Bug Bounties and Security Research Programs

Many companies operate bug bounty programs through platforms like HackerOne, Bugcrowd, or Intigriti. These programs define specific targets (apps, APIs, domains), rules of engagement, and reward structures. For mobile application testing, check whether:

- The mobile app is explicitly in scope (not all bounty programs include mobile)
- Reverse engineering and binary modification are permitted (some programs exclude these techniques)
- The program covers the specific attack surfaces you're testing (camera injection might not be covered under a typical "web and API" bounty scope)
- There's a safe harbor clause that protects good-faith researchers

Bug bounty programs are excellent for individual vulnerability discovery, but they're typically not designed for the kind of coordinated, multi-surface engagements this book teaches. For comprehensive red team testing, a formal engagement is the right framework.

### What Not to Do

- Don't test production systems without authorization, even to verify a vulnerability you suspect
- Don't access or exfiltrate user data to "prove" the impact of a vulnerability
- Don't threaten to publish if the vendor doesn't respond or doesn't pay a bounty
- Don't coordinate with other researchers to pressure a vendor
- Don't publish detailed bypass techniques without giving the vendor reasonable time to deploy fixes

---

## The Ethical Operator's Checklist

Before every engagement — even a lab exercise — run through this checklist. It takes thirty seconds and prevents the kind of mistakes that end careers.

**Before Testing:**
- [ ] Written authorization from the target owner or their authorized representative
- [ ] Scope document defining in-scope and out-of-scope targets, surfaces, and timeframes
- [ ] Legal review completed (for real engagements — not required for personal lab exercises)
- [ ] No real user biometric data in payloads — use synthetic faces, test documents, fabricated coordinates
- [ ] Test device is isolated or clearly designated for security testing
- [ ] Communication channel with the client established (for real engagements)

**During Testing:**
- [ ] Stay within scope — if you discover something outside the authorized boundary, stop and report
- [ ] Document everything — screenshots, logs, commands, timestamps
- [ ] Use minimum necessary access — don't harvest data beyond what's needed to demonstrate the finding
- [ ] If you accidentally impact production or trigger an alert, contact the client immediately

**After Testing:**
- [ ] Findings reported to the target owner through the agreed channel
- [ ] Report includes remediation recommendations, not just vulnerability descriptions
- [ ] Test data (injected frames, captured logs, screenshots with sensitive data) securely deleted or retained per agreement
- [ ] Debrief with the client to discuss findings and answer questions
- [ ] Not published without the client's consent

---

## When to Stop

Sometimes you encounter situations during an engagement that fall outside what you anticipated. Knowing when to stop is as important as knowing how to proceed.

### Out-of-Scope Discovery

You're testing a KYC app's camera injection surface and you notice the app makes unencrypted API calls that leak user tokens. That's a real vulnerability — but if API security wasn't in your scope, you don't probe further. Document what you observed, report it as an incidental finding, and let the client decide whether to add it to the scope.

### Evidence of Actual Fraud

During recon, you discover the app contains code paths that look like they were inserted by someone else — perhaps an actual attacker has already compromised the build pipeline. Stop testing. Report the finding to your client's incident response team immediately. This is no longer a penetration test — it's a potential active compromise.

### Unexpected Data Exposure

Your testing inadvertently surfaces real user data — perhaps the staging environment contains production data, or a debug endpoint returns user records. Stop accessing the data immediately. Document what you saw (including that you stopped as soon as you realized), and report it to the client. Do not capture, copy, or retain the data.

### The "Pause and Report" Protocol

When any of these situations arise, follow this protocol:

1. **Stop** the current test action immediately
2. **Document** what you observed, including timestamps
3. **Contact** the engagement point of contact within one hour
4. **Wait** for guidance before resuming testing
5. **Record** the pause in your engagement log

---

## Biometric Data: Special Considerations

The techniques in this book involve creating, handling, and injecting biometric data — face images, motion profiles, and identity document images. Even in a testing context, this data requires special handling.

### Synthetic vs. Real Data

**Always use synthetic data in testing.** This means:

- **Face frames:** Generate from your own video (you consenting to your own biometric capture) or use AI-generated faces that don't correspond to real people. Never use photographs of other people without their explicit, documented consent.
- **Identity documents:** Use clearly fabricated documents with obviously fake information. Never photograph or scan real identity documents for use as test payloads.
- **Location data:** Use well-known public locations (Times Square, Googleplex, etc.) that can't be linked to any individual's real location patterns.

### Data Retention

After an engagement, your test data should be handled according to the data handling terms in your engagement agreement. In general:

- **Engagement evidence** (screenshots, logs showing the bypass worked) is retained as part of the deliverable
- **Raw payloads** (face frames, document images) should be securely deleted after the engagement unless the client requests otherwise
- **Delivery logs** may contain biometric processing artifacts — review them before including in reports
- **Never retain test data "for future use"** unless specifically authorized

### Why This Matters

In 2023, multiple jurisdictions introduced or strengthened biometric data protection laws. Illinois's Biometric Information Privacy Act (BIPA) imposes statutory damages of $1,000-$5,000 per violation for mishandling biometric data. The EU's GDPR classifies biometric data as a special category with heightened protection requirements. Even in a security testing context, mishandling biometric data creates legal liability.

The safe path is simple: use your own face, use fabricated documents, and delete the data when you're done.

---

## Ethics Callouts: A Format for This Book

Throughout the remaining chapters, you'll encounter callout boxes like this:

> **Ethics Note:** The techniques in this chapter can **demonstrate weaknesses in** [specific defense]. Use them only against targets you are authorized to test. Ensure your payloads use synthetic data, not real users' biometric information.

These callouts appear at the start of chapters where the content has direct security-testing application. They're operational reminders, not a substitute for legal advice. When you're deep in the technical details of making a frame injection work, it's easy to lose sight of the broader context. The callouts bring you back to it.

Consider them part of the methodology. A professional operator thinks about authorization at every step, not just at the beginning of the engagement.

---

## What Comes Next

With the rules established, Chapter 3 dives into the technology that makes all of this possible. You'll learn how Android delivers camera frames, GPS fixes, and sensor readings to applications — the architecture that creates the surfaces you'll spend the rest of this book assessing under authorization. Understanding *why* the hooks work at an architectural level is what separates an operator who can run the tools from one who can adapt when things don't go as expected.

---

### References: Legal Texts and Primary Sources

**United States**
- [18 U.S.C. § 1030 — Computer Fraud and Abuse Act (CFAA)](https://www.law.cornell.edu/uscode/text/18/1030)
- [17 U.S.C. § 1201 — DMCA Anti-Circumvention](https://www.law.cornell.edu/uscode/text/17/1201)
- [17 U.S.C. § 1201(j) — Security Testing Exemption](https://www.law.cornell.edu/uscode/text/17/1201)
- [Van Buren v. United States, 593 U.S. 374 (2021)](https://supreme.justia.com/cases/federal/us/593/374/)
- [U.S. Copyright Office — Section 1201 Rulemaking](https://www.copyright.gov/1201/)
- [740 ILCS 14 — Illinois Biometric Information Privacy Act (BIPA)](https://www.ilga.gov/legislation/ilcs/ilcs3.asp?ActID=3004)

**United Kingdom**
- [Computer Misuse Act 1990](https://www.legislation.gov.uk/ukpga/1990/18/contents)

**European Union**
- [Regulation (EU) 2024/2847 — Cyber Resilience Act (CRA)](https://eur-lex.europa.eu/eli/reg/2024/2847/oj)
- [Directive (EU) 2022/2555 — NIS2 Directive](https://eur-lex.europa.eu/eli/dir/2022/2555/oj)
- [Regulation (EU) 2016/679 — General Data Protection Regulation (GDPR)](https://eur-lex.europa.eu/eli/reg/2016/679/oj)
- [GDPR Article 9 — Processing of Special Categories of Personal Data](https://gdpr-info.eu/art-9-gdpr/)

**Other Jurisdictions**
- [Criminal Code Act 1995 (Australia), Part 10.7](https://www.legislation.gov.au/C2004A04868/latest/text)
- [Criminal Code (Canada), Section 342.1](https://laws-lois.justice.gc.ca/eng/acts/c-46/page-73.html)
- [Computer Misuse Act (Singapore)](https://sso.agc.gov.sg/Act/CMA1993)
- [Cybersecurity Act 2018 (Singapore)](https://sso.agc.gov.sg/Act/CA2018)
- [Act on Prohibition of Unauthorized Computer Access (Japan)](https://www.japaneselawtranslation.go.jp/en/laws/view/2441)

**Industry Standards and Frameworks**
- [OWASP Mobile Application Security Testing Guide (MASTG)](https://mas.owasp.org/MASTG/)
- [OWASP Mobile Application Security Verification Standard (MASVS)](https://mas.owasp.org/MASVS/)
- [HackerOne — Vulnerability Disclosure Programs](https://www.hackerone.com/)
- [Bugcrowd — Bug Bounty Platform](https://www.bugcrowd.com/)
- [Intigriti — Bug Bounty Platform](https://www.intigriti.com/)
