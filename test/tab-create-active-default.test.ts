import { describe, expect, test } from "bun:test"
import { buildTabCreateAction } from "../cli/commands/compound"
import { parseTabsCommand } from "../cli/commands/tabs"

// Background-first contract for tab creation.
//
// These tests pin the **default** behavior: a plain `interceptor open <url>`
// or `interceptor tab new <url>` must not carry `active: true` on the
// `tab_create` action it builds. The extension handler reads
// `action.active === true` as the activate signal, so the absence of the
// field — or `active: false` — both route to a background tab via
// `chrome.tabs.create({ active: false })`. The activate path is covered in
// tab-create-activate-flag.test.ts.

describe("tab_create — background-first default", () => {
  test("interceptor open <url> omits active by default", () => {
    const action = buildTabCreateAction(["open", "https://example.com"], "https://example.com")
    expect(action).toEqual({ type: "tab_create", url: "https://example.com" })
    expect("active" in action).toBe(false)
  })

  test("interceptor open <url> with unrelated flags still omits active", () => {
    const action = buildTabCreateAction(
      ["open", "https://example.com", "--full", "--tree-only", "--timeout", "8000"],
      "https://example.com"
    )
    expect(action.active).toBeUndefined()
  })

  test("interceptor open <url> --reuse keeps active undefined", () => {
    const action = buildTabCreateAction(
      ["open", "https://example.com", "--reuse"],
      "https://example.com"
    )
    expect(action.reuse).toBe(true)
    expect(action.active).toBeUndefined()
  })

  test("interceptor tab new <url> omits active by default", async () => {
    const action = await parseTabsCommand(["tab", "new", "https://example.com"])
    expect(action).not.toBeNull()
    expect(action).toMatchObject({ type: "tab_create", url: "https://example.com" })
    expect("active" in (action as Record<string, unknown>)).toBe(false)
  })

  test("extension handler treats undefined active as background (active=false)", () => {
    // Mirror the exact gate in extension/src/background/capabilities/tabs.ts:
    //   const shouldActivate = (action.active as boolean | undefined) === true
    // Anything other than literal `true` must resolve to background.
    const cases: Array<{ active?: unknown; expected: boolean }> = [
      { expected: false },                       // undefined
      { active: undefined, expected: false },
      { active: false, expected: false },
      { active: 0, expected: false },
      { active: "true", expected: false },       // not boolean true — still background
      { active: null, expected: false },
      { active: true, expected: true }            // only literal true activates
    ]
    for (const c of cases) {
      const shouldActivate = (c.active as boolean | undefined) === true
      expect(shouldActivate).toBe(c.expected)
    }
  })
})
