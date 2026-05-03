const IS_WIN = process.platform === "win32"
const IS_MAC = process.platform === "darwin"

const notSupported = (name: string) => (..._args: unknown[]) =>
  Promise.resolve({ success: false, error: `${name} requires macOS (full mode)` })

const mod = IS_WIN
  ? await import("./os-input-win")
  : IS_MAC
    ? await import("./os-input")
    : null

export const osClick = mod?.osClick ?? notSupported("osClick")
export const osKey = mod?.osKey ?? notSupported("osKey")
export const osType = mod?.osType ?? notSupported("osType")
export const osMove = mod?.osMove ?? notSupported("osMove")
export const generateBezierPath = mod?.generateBezierPath ??
  ((_fx: number, _fy: number, _tx: number, _ty: number, steps = 20) => {
    const pts = []
    for (let i = 0; i <= steps; i++) pts.push({ x: 0, y: 0 })
    return pts
  })
export const translateCoords = mod?.translateCoords ??
  ((pageX: number, pageY: number, wb: { left: number; top: number }, uiH = 88) =>
    ({ screenX: wb.left + pageX, screenY: wb.top + uiH + pageY }))
