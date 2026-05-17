/// <reference lib="dom" />

import { afterEach, beforeEach, describe, expect, test } from "bun:test"

// captureVisibleTab focus borrow-and-restore.
//
// `chrome.tabs.captureVisibleTab` captures whichever tab is **active** in the
// window, not the tabId you pass. Once `tab_create` defaults to `active:
// false`, a naive screenshot would silently capture the user's foreground
// tab. `withCaptureVisibleTabFocus` mitigates this: query the currently-active
// tab in the window, activate our target, run the capture closure, then
// restore the prior-active tab regardless of success or failure.
//
// These tests stub `globalThis.chrome.tabs` with a deterministic fake and
// verify: (1) the prior-active tab is identified, (2) the target gets
// activated when it wasn't already, (3) the closure runs with the target
// active, (4) the prior-active tab is restored after success and after
// failure, (5) when the target was already active no extra updates fire.

type UpdateCall = { tabId: number; props: chrome.tabs.UpdateProperties }

interface FakeTab {
  id: number
  active: boolean
  windowId: number
}

let activations: UpdateCall[]
let fakeTabs: FakeTab[]
let originalChrome: unknown

function installFakeChrome(tabs: FakeTab[]) {
  fakeTabs = tabs
  activations = []
  originalChrome = (globalThis as { chrome?: unknown }).chrome
  ;(globalThis as { chrome: unknown }).chrome = {
    tabs: {
      query: async (q: chrome.tabs.QueryInfo) => {
        return fakeTabs.filter(t =>
          (q.active === undefined || t.active === q.active) &&
          (q.windowId === undefined || t.windowId === q.windowId)
        )
      },
      update: async (tabId: number, props: chrome.tabs.UpdateProperties) => {
        activations.push({ tabId, props })
        if (props.active === true) {
          for (const t of fakeTabs) {
            if (t.windowId === fakeTabs.find(x => x.id === tabId)?.windowId) {
              t.active = t.id === tabId
            }
          }
        }
        return fakeTabs.find(t => t.id === tabId)
      }
    }
  }
}

function restoreChrome() {
  ;(globalThis as { chrome?: unknown }).chrome = originalChrome
}

beforeEach(() => {
  // Default scenario: window 1 has two tabs — 100 (active, user's foreground)
  // and 200 (background, the Interceptor-managed target).
  installFakeChrome([
    { id: 100, active: true, windowId: 1 },
    { id: 200, active: false, windowId: 1 }
  ])
})

afterEach(() => {
  restoreChrome()
})

describe("withCaptureVisibleTabFocus — borrow-and-restore", () => {
  test("activates the background target then restores the prior-active tab on success", async () => {
    const { withCaptureVisibleTabFocus } = await import("../extension/src/background/capabilities/screenshot")
    let observedActiveDuringCapture: number | undefined
    const result = await withCaptureVisibleTabFocus(200, 1, async () => {
      observedActiveDuringCapture = fakeTabs.find(t => t.active && t.windowId === 1)?.id
      return "capture-payload"
    })
    expect(result).toBe("capture-payload")
    expect(observedActiveDuringCapture).toBe(200)
    expect(activations).toEqual([
      { tabId: 200, props: { active: true } },
      { tabId: 100, props: { active: true } }
    ])
    // Final state: prior-active tab is active again.
    expect(fakeTabs.find(t => t.id === 100)?.active).toBe(true)
    expect(fakeTabs.find(t => t.id === 200)?.active).toBe(false)
  })

  test("restores the prior-active tab even when the closure throws", async () => {
    const { withCaptureVisibleTabFocus } = await import("../extension/src/background/capabilities/screenshot")
    await expect(
      withCaptureVisibleTabFocus(200, 1, async () => {
        throw new Error("capture failed")
      })
    ).rejects.toThrow("capture failed")
    expect(activations).toEqual([
      { tabId: 200, props: { active: true } },
      { tabId: 100, props: { active: true } }
    ])
    expect(fakeTabs.find(t => t.id === 100)?.active).toBe(true)
  })

  test("no-op when the target tab was already active — closure still runs", async () => {
    fakeTabs[0].active = false
    fakeTabs[1].active = true
    const { withCaptureVisibleTabFocus } = await import("../extension/src/background/capabilities/screenshot")
    let ran = false
    await withCaptureVisibleTabFocus(200, 1, async () => { ran = true })
    expect(ran).toBe(true)
    expect(activations).toEqual([])
    expect(fakeTabs.find(t => t.id === 200)?.active).toBe(true)
  })

  test("ignores activation errors and surfaces capture-closure errors verbatim", async () => {
    // Replace chrome.tabs.update with a thrower for the initial activate call,
    // then succeed on the restore. The capture closure runs regardless.
    let updateCalls = 0
    const chromeUnderTest = (globalThis as { chrome: { tabs: { update: (id: number, props: chrome.tabs.UpdateProperties) => Promise<unknown> } } }).chrome
    const originalUpdate = chromeUnderTest.tabs.update
    chromeUnderTest.tabs.update = async (tabId: number, props: chrome.tabs.UpdateProperties) => {
      updateCalls++
      if (updateCalls === 1) throw new Error("tab vanished")
      return originalUpdate(tabId, props)
    }
    const { withCaptureVisibleTabFocus } = await import("../extension/src/background/capabilities/screenshot")
    const out = await withCaptureVisibleTabFocus(200, 1, async () => "captured-anyway")
    expect(out).toBe("captured-anyway")
    // Final restore call was issued even though the initial activate threw.
    expect(updateCalls).toBe(2)
  })

  test("does not restore when prior-active tab is the same as the target (no spurious update)", async () => {
    fakeTabs[0].active = false
    fakeTabs[1].active = true   // target is already the active one
    const { withCaptureVisibleTabFocus } = await import("../extension/src/background/capabilities/screenshot")
    await withCaptureVisibleTabFocus(200, 1, async () => undefined)
    expect(activations).toEqual([])
  })
})
