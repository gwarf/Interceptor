import { afterEach, describe, expect, test } from "bun:test"

class FakeWebSocket {
  static CONNECTING = 0
  static OPEN = 1
  static CLOSING = 2
  static CLOSED = 3

  static instances: FakeWebSocket[] = []

  readyState = FakeWebSocket.CONNECTING
  onopen: (() => void | Promise<void>) | null = null
  onmessage: ((event: { data: string }) => void) | null = null
  onclose: (() => void) | null = null
  onerror: (() => void) | null = null
  sent: string[] = []

  constructor(readonly url: string) {
    FakeWebSocket.instances.push(this)
  }

  send(data: string): void {
    this.sent.push(data)
  }

  close(): void {
    this.readyState = FakeWebSocket.CLOSED
    this.onclose?.()
  }
}

const originalWebSocket = globalThis.WebSocket
const hadOriginalChrome = Object.prototype.hasOwnProperty.call(globalThis, "chrome")
const originalChrome = (globalThis as { chrome?: unknown }).chrome

function installFakeChrome(): void {
  const addListener = () => {}
  ;(globalThis as { chrome: unknown }).chrome = {
    action: {
      setBadgeText: () => {},
      setBadgeBackgroundColor: () => {},
    },
    runtime: {
      onMessage: { addListener },
    },
    storage: {
      local: {
        get: async () => ({}),
        set: async () => {},
      },
    },
    scripting: {
      unregisterContentScripts: async () => {},
      registerContentScripts: async () => {},
    },
    tabs: {
      onActivated: { addListener },
      onCreated: { addListener },
      onRemoved: { addListener },
    },
    webNavigation: {
      getFrame: async () => undefined,
      onCommitted: { addListener },
      onCompleted: { addListener },
      onHistoryStateUpdated: { addListener },
      onReferenceFragmentUpdated: { addListener },
      onTabReplaced: { addListener },
    },
  }
}

afterEach(() => {
  ;(globalThis as { WebSocket: typeof WebSocket }).WebSocket = originalWebSocket
  if (hadOriginalChrome) {
    ;(globalThis as { chrome?: unknown }).chrome = originalChrome
  } else {
    delete (globalThis as { chrome?: unknown }).chrome
  }
  FakeWebSocket.instances = []
})

describe("extension websocket lifecycle", () => {
  test("coalesces overlapping websocket connection attempts before onopen", async () => {
    ;(globalThis as { WebSocket: typeof WebSocket }).WebSocket = FakeWebSocket as unknown as typeof WebSocket
    installFakeChrome()

    const { connectWsChannel } = await import("../extension/src/background/transport")

    connectWsChannel()
    connectWsChannel()

    expect(FakeWebSocket.instances).toHaveLength(1)
    expect(FakeWebSocket.instances[0].url).toBe("ws://localhost:19222")
    expect(FakeWebSocket.instances[0].sent).toEqual([])
  })
})
