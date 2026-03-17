// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

export default defineConfig({
	site: 'https://iamjosephmj.github.io',
	base: '/AndroidRedTeam',
	integrations: [
		starlight({
			title: 'Android Red Team',
			description: 'Bytecode-level biometric bypass for Android KYC and liveness verification',
			logo: {
				src: './src/assets/logo.svg',
				alt: 'Android Red Team',
			},
			favicon: '/favicon.svg',
			customCss: ['./src/styles/custom.css'],
			social: [
				{ icon: 'github', label: 'GitHub', href: 'https://github.com/iamjosephmj/AndroidRedTeam' },
			],
			head: [
				{
					tag: 'meta',
					attrs: { property: 'og:image', content: 'https://iamjosephmj.github.io/AndroidRedTeam/og-image.png' },
				},
				{
					tag: 'meta',
					attrs: { name: 'theme-color', content: '#7c3aed' },
				},
			],
			sidebar: [
				{
					label: 'Book',
					items: [
						{
							label: 'Part I: Foundations',
							items: [
								{ label: '1. The Threat Landscape', slug: 'book/foundations/01-threat-landscape' },
								{ label: '2. Rules of Engagement', slug: 'book/foundations/02-rules-of-engagement' },
								{ label: '3. Android Internals', slug: 'book/foundations/03-android-internals' },
								{ label: '4. The Lab', slug: 'book/foundations/04-the-lab' },
							],
						},
						{
							label: 'Part II: The Toolkit',
							items: [
								{ label: '5. Reconnaissance', slug: 'book/toolkit/05-reconnaissance' },
								{ label: '6. The Injection Pipeline', slug: 'book/toolkit/06-injection-pipeline' },
								{ label: '7. Camera Injection', slug: 'book/toolkit/07-camera-injection' },
								{ label: '8. Location Spoofing', slug: 'book/toolkit/08-location-spoofing' },
								{ label: '9. Sensor Injection', slug: 'book/toolkit/09-sensor-injection' },
							],
						},
						{
							label: 'Part III: Operations',
							items: [
								{ label: '10. Full Engagement', slug: 'book/operations/10-full-engagement' },
								{ label: '11. Evidence & Reporting', slug: 'book/operations/11-evidence-reporting' },
								{ label: '12. Scaling Operations', slug: 'book/operations/12-scaling-operations' },
							],
						},
						{
							label: 'Part IV: Advanced',
							items: [
								{ label: '13. Smali Fundamentals', slug: 'book/advanced/13-smali-fundamentals' },
								{ label: '14. Custom Hooks', slug: 'book/advanced/14-custom-hooks' },
								{ label: '15. Anti-Tamper Evasion', slug: 'book/advanced/15-anti-tamper' },
								{ label: '16. Automated Pipelines', slug: 'book/advanced/16-automated-pipelines' },
							],
						},
						{
							label: 'Part V: Defense',
							items: [
								{ label: '17. Blue Team Detection', slug: 'book/defense/17-blue-team-detection' },
								{ label: '18. Defense-in-Depth', slug: 'book/defense/18-defense-in-depth' },
							],
						},
						{
							label: 'Appendices',
							items: [
								{ label: 'A. Quick Reference', slug: 'book/appendices/a-cheatsheet' },
								{ label: 'B. Smali Reference', slug: 'book/appendices/b-smali-reference' },
								{ label: 'C. Target Catalog', slug: 'book/appendices/c-target-catalog' },
								{ label: 'D. Tool Versions', slug: 'book/appendices/d-tool-versions' },
							],
						},
					],
				},
				{
					label: 'Labs',
					items: [
						{ label: '0. Environment Verification', slug: 'labs/00-environment-verification' },
						{ label: '1. APK Recon', slug: 'labs/01-recon' },
						{ label: '2. First Injection', slug: 'labs/02-first-injection' },
						{ label: '3. Camera Injection', slug: 'labs/03-camera-injection' },
						{ label: '4. Location Spoofing', slug: 'labs/04-location-spoofing' },
						{ label: '5. Sensor Injection', slug: 'labs/05-sensor-injection' },
						{ label: '6. Full Engagement', slug: 'labs/06-full-engagement' },
						{ label: '7. Smali Reading', slug: 'labs/07-smali-reading' },
						{ label: '8. Custom Hooks', slug: 'labs/08-custom-hooks' },
						{ label: '9. Automated Engagement', slug: 'labs/09-automated-engagement' },
						{ label: '10. Anti-Tamper Evasion', slug: 'labs/10-anti-tamper' },
						{ label: '11. Batch Operations', slug: 'labs/11-batch-operations' },
						{ label: '12. Build Your Own Target', slug: 'labs/12-build-target' },
						{ label: '13. Defend and Attack', slug: 'labs/13-defend-and-attack' },
					],
				},
				{
					label: 'Cheatsheet',
					items: [
						{ label: 'Quick Reference', slug: 'cheatsheet' },
					],
				},
			],
		}),
	],
});
