---
name: gen-git-commit-msg
description: Generate a high-quality Conventional Commits v1.0.0 git commit message from staged changes or a provided diff. Use this skill whenever the user runs /gen-git-commit-msg, asks to generate a commit message, wants to write a git commit, or provides a diff/code change and wants a commit. Always use this skill for any git commit message generation task.
---

# gen-git-commit-msg

Generate a high-quality git commit message following Conventional Commits v1.0.0.

## Step 1: Gather the diff

Use the following priority order:

1. **User-provided diff** — if the user pasted a diff or code change in the message, use that directly. Do NOT run any git commands.
2. **Staged changes** — if nothing was provided, run:
   ```bash
   git diff --cached
   ```
3. **Unstaged changes** — if nothing is staged, run:
   ```bash
   git diff HEAD
   ```
4. **Still empty** — tell the user: "No diff found. Please paste a diff or stage your changes first."

> The user may provide any arbitrary diff — branch comparisons, cherry-picks, patch files, etc. Accept and process whatever is given.

---

## Step 2: Analyze the diff

Before writing, identify:
- What changed (files, modules, logic)
- Why it changed (bug fix, new feature, refactor, etc.)
- The scope (which module or domain)
- Whether there are breaking changes

---

## Step 3: Generate the commit message

Follow ALL rules below strictly.

### Header format
```
<type>(<optional scope>): <description>
```

**type** — choose one:
`feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`

**scope** (optional):
- lowercase
- represents a module or domain (e.g. `mavlink`, `control`, `parser`, `api`, `auth`)
- include it if determinable from the diff

**description**:
- English, imperative mood
- max 50 characters
- no period at end
- no capital first letter
- structure: `action + target + core purpose`
- if multiple actions, connect with `and`

---

### Body (strongly recommended)

**Paragraph 1 — High-level purpose:**
- Describe system-level impact or summary of the change
- Emphasize: stability / correctness / predictability / performance

*(blank line)*

**Bullet points — Key changes:**
Format: `- <What changed> to <Why>`

Examples:
- replace X to prevent Y
- remove Z to maintain W
- adjust A to improve B

Rules:
- each line ≤ 72 characters
- focus on reason and effect, not raw diff description
- avoid meaningless lines like "rename variable"

---

### Footer (optional)
```
BREAKING CHANGE: <description>
Closes #<issue_number>
```

---

## Step 4: Output format

Output MUST follow this exact structure:

1. First, output the full commit message translated into **繁體中文**
2. A separator line: `---`
3. Then output the **English commit message** (the actual one to use)

Example output structure:
```
feat(auth): 新增 JWT 令牌刷新並防止過期登出

此次修改解決了用戶在長時間閒置後被強制登出的問題，
提升了認證流程的穩定性與可預測性。

- 新增 refreshToken 方法以在過期前自動延長 session
- 移除硬編碼的超時常數以改善可維護性
- 調整錯誤處理邏輯以統一回應格式

---

feat(auth): add JWT token refresh and prevent expiry logout

Resolves silent session termination after idle periods,
improving auth flow stability and user predictability.

- add refreshToken method to auto-extend session before expiry
- remove hardcoded timeout constant to improve maintainability
- adjust error handler to unify response format
```

---

## Principles

- One commit = one logical unit
- Describe **intent**, not diff details
- Prioritize readability and engineering value
- Avoid mechanical or meaningless messages
