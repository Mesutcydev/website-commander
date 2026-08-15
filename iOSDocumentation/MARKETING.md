# Website Commander Super — Marketing & App Store Assets

This document contains the finalized marketing copy, headlines, pitches, and exact App Store screenshot specifications for **Website Commander Super**.

---

## App Review Metadata Fixes

Do not promote the In-App Purchases on the App Store for this submission. In App Store Connect, remove the App Store promotional images for both IAP products and make sure neither product is selected for App Store promotion.

Keep the product metadata distinct in case it is shown during purchase or reviewed again:

| Product | Display Name | Description |
| --- | --- | --- |
| Monthly subscription | Website Commander Super Monthly | Unlimited sites, inspector, routing |
| Yearly subscription | Website Commander Super Yearly | Best value yearly Super access |
| Lifetime unlock | Website Commander Super Lifetime | One-time unlock for Super features |

Add this line to the App Store app description when using Apple's standard EULA:

> Terms of Use: https://www.apple.com/legal/internet-services/itunes/dev/stdeula/

Add this to the App Review notes:

> We are no longer promoting these In-App Purchases on the App Store. The associated promotional images have been removed/disabled in App Store Connect. The app description now includes the Apple standard Terms of Use link, and the paywall includes functional Terms of Use and Privacy Policy links.

---

## 1. Marketing Copy

### Paywall Headlines (3 Premium Options)
*   **Option 1 (Benefit-Focused):**
    > **"Your AI Website Command Center"**
    *Why it works:* Establishes the app as the single point of control for all web assets, speaking directly to developers, designers, and site managers.
*   **Option 2 (Action-Oriented):**
    > **"Manage & Deploy Unlimited Sites with AI"**
    *Why it works:* Highlights the core value proposition (unlimited websites) and the autonomous capability of the agent.
*   **Option 3 (Trust/Integration-Oriented):**
    > **"Supercharge Your Web Workflow"**
    *Why it works:* Premium and energetic headline focused on workflow speed, integration with Claude/Copilot/DeepSeek, and Git safety.

### Subheadline
> "Connect any static or headless site. Write in plain English. Review side-by-side diffs, and deploy with confidence. Powered by Claude, Copilot, and DeepSeek."

### Feature List (with iOS SF Symbol Recommendations)
*   **folder.badge.plus** — **Unlimited Sites:** Add all your web projects (Vanilla HTML, Astro, Next.js, Hugo, Jekyll) and switch between workspace command centers in one tap.
*   **cpu** — **Smart Model Routing:** Fallback chain routing that uses Claude for planning, Copilot for code-aware edits, and DeepSeek for high-speed bulk edits.
*   **arrow.triangle.2.circlepath** — **Safe Git Workflow:** Autonomous loops stage changes in a temporary branch first. You review side-by-side diffs before committing.
*   **ant.fill** — **Advanced Web Inspector:** Inspect HTML elements, read console logs, monitor network requests, and check performance metrics directly in-app.
*   **infinity** — **Unlimited Agent Loops:** Free yourself from rate limits. Run multi-step agent actions to write blog posts, optimize SEO, and refresh code elements.

### Urgency & Benefit Statements
*   *"Save hours of development time. Manage your static portfolios, blogs, and landing pages directly from your iPhone."*
*   *"Never write boilerplate deploy scripts again. Website Commander handles the git staging, assets optimization, and triggers Cloudflare/Netlify builds automatically."*
*   *"Start your 7-day free trial today and deploy your first AI-generated change in less than 60 seconds. Cancel anytime in Apple ID settings."*

### Lifetime Value Pitch
*   **"Own Your Workflow Forever."**
    > "Get lifetime access to Website Commander Super for a single, one-time payment of $19.99. No recurring charges, no subscriptions, and all future app updates included. Unlock unlimited sites, the advanced inspector, smart routing, and Super workflows forever. Third-party AI providers may still require your own account or API key."

---

## 2. App Store Screenshot Descriptions (6 Screenshots)

Designed for a premium, dark-mode first look utilizing sleek, rounded iPhone mockups, modern typography (such as *Outfit* or *SF Pro*), and vibrant indigo/blue backgrounds with subtle neon accents.

### Screenshot 1: Hero / Welcome
*   **Exact Text Overlay:** 
    *   *Headline:* **Your AI Website Command Center**
    *   *Sub-caption:* Manage & deploy websites in plain English.
*   **Visual Description:**
    *   iPhone mockup showcasing the main **Command Center Dashboard** (`HomeDashboardView`).
    *   Highlighted elements: A green "Connected" status dot at the top, a card showing "Sites Connected: 5", and a preview card showing the active site (e.g. `mesut.uk`).
    *   Background: Dark indigo space gradient.

### Screenshot 2: Chat with AI Agent
*   **Exact Text Overlay:**
    *   *Headline:* **Describe Changes, Staged in Seconds**
    *   *Sub-caption:* Claude, Copilot, & DeepSeek write your code.
*   **Visual Description:**
    *   iPhone mockup showcasing the **AI Agent Chat Interface** (`ChatView`).
    *   Chat bubbles: 
        *   User: *"Add a new project card to my portfolio homepage for 'Website Commander iOS' with details."*
        *   Agent: *"Understood. I have staged edits to `index.html` and uploaded `website-commander-card.jpg`."*
    *   The "Pending Changes Bar" is visible at the bottom with a pulsing indicator.

### Screenshot 3: Live Preview & Web Inspector
*   **Exact Text Overlay:**
    *   *Headline:* **Advanced In-App Web Inspector**
    *   *Sub-caption:* Run JS console, monitor network & compute styles.
*   **Visual Description:**
    *   iPhone mockup showing the split **Preview & Debug view** (`SitePreviewView`).
    *   Top half shows a beautiful rendering of the website portfolio.
    *   Bottom half shows the floating Web Inspector toolbar with the **Console tab** active, showing JS logs and a command input (`window.location`).
    *   A yellow highlight border is visible on one of the page's headings to represent inspect-mode.

### Screenshot 4: Multi-Site Dashboard
*   **Exact Text Overlay:**
    *   *Headline:* **Manage Unlimited Web Workspaces**
    *   *Sub-caption:* Supports Astro, Next.js, Hugo, and vanilla HTML.
*   **Visual Description:**
    *   iPhone mockup showing the **Workspaces screen** (`SitesManagerView` / `SettingsView`).
    *   A list of multiple connected sites, each with Tech Stack badges (e.g., `Astro`, `Next.js`, `Vanilla HTML`) and Deployment badges (e.g., `Cloudflare Pages`, `Vercel`).
    *   Active workspace marked with a prominent checkmark.

### Screenshot 5: Diff & Approval Screen
*   **Exact Text Overlay:**
    *   *Headline:* **Safe Git Workflow & Code Diffs**
    *   *Sub-caption:* Approve edits before they go live.
*   **Visual Description:**
    *   iPhone mockup showing the **Diff Approval Screen** (`DiffApprovalView`).
    *   Beautiful side-by-side or unified code editor showing green-colored additions (e.g. `+ <div class="project-card">`) and red-colored deletions.
    *   Bottom CTA: A large, glowing indigo button labeled **"Approve & Commit Changes"**.

### Screenshot 6: Paywall / Pricing Screen
*   **Exact Text Overlay:**
    *   *Headline:* **Unlock Website Commander Super**
    *   *Sub-caption:* Choose the plan that fits your developer workflow.
*   **Visual Description:**
    *   iPhone mockup showing the **Paywall screen** (`ProPaywall`).
    *   Highlights the comparison table (Free vs Super) showing "Unlimited Sites", "Advanced Web Inspector", and "Smart Routing" checked for Super.
    *   The two premium buttons:
        *   **Super Monthly:** $1.99/mo (glowing border, labeled "7 DAYS FREE TRIAL")
        *   **Super Lifetime:** $19.99 (yellow border, labeled "BEST VALUE")
