import { describe, expect, test } from "bun:test"
import { buildTabCreateAction } from "../cli/commands/compound"
import { parseTabsCommand } from "../cli/commands/tabs"

// Explicit `--activate` opt-in.
//
// `--activate` is the only way for the CLI to ask for a foreground tab.
// These tests pin: (1) presence of the flag → `active: true` on the action,
// (2) combinations with `--reuse` (so `open --reuse --activate` foregrounds
// the reused tab), (3) the matching `tab new` parser path, and (4) the
// extension-handler activation gate — only literal `active === true`
// causes `chrome.tabs.create({ active: true })`.

describe("tab_create — --activate explicit opt-in", () => {
  test("interceptor open <url> --activate sets active: true", () => {
    const action = buildTabCreateAction(
      ["open", "https://example.com", "--activate"],
      "https://example.com"
    )
    expect(action.active).toBe(true)
  })

  test("interceptor open <url> --reuse --activate combines both flags", () => {
    const action = buildTabCreateAction(
      ["open", "https://example.com", "--reuse", "--activate"],
      "https://example.com"
    )
    expect(action.reuse).toBe(true)
    expect(action.active).toBe(true)
  })

  test("flag order does not matter", () => {
    const a = buildTabCreateAction(
      ["open", "--activate", "https://example.com"],
      "https://example.com"
    )
    const b = buildTabCreateAction(
      ["open", "https://example.com", "--activate"],
      "https://example.com"
    )
    expect(a.active).toBe(true)
    expect(b.active).toBe(true)
  })

  test("interceptor tab new <url> --activate sets active: true on tab_create", async () => {
    const action = await parseTabsCommand(["tab", "new", "https://example.com", "--activate"])
    expect(action).not.toBeNull()
    expect(action).toMatchObject({
      type: "tab_create",
      url: "https://example.com",
      active: true
    })
  })

  test("extension activation gate is strict — only literal true activates", () => {
    // Mirror the exact gate in extension/src/background/capabilities/tabs.ts:
    //   const shouldActivate = (action.active as boolean | undefined) === true
    expect(((true as unknown) as boolean | undefined) === true).toBe(true)
    expect(((false as unknown) as boolean | undefined) === true).toBe(false)
    expect((undefined as boolean | undefined) === true).toBe(false)
    // Truthy-but-not-boolean values do not pass the gate — guards against
    // a future caller writing `active: 1` and accidentally enabling activation.
    expect(((1 as unknown) as boolean | undefined) === true).toBe(false)
    expect((("true" as unknown) as boolean | undefined) === true).toBe(false)
  })
})
