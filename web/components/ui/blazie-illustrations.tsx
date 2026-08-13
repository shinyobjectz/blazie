/**
 * Three drawings of the three ideas.
 *
 * Each one is the claim beside it, made visible — a fact naming what produced
 * it, a fence with a door on one side, and an edge that is just a fact. They
 * are deliberately schematic: a diagram that flatters is a diagram that lies,
 * and every shape here corresponds to something in `lib/blazie`.
 *
 * Flat SVG, no animation library, no images. They sit at the foot of a card and
 * are `aria-hidden` — the prose above carries the meaning.
 */

const FLAME = "var(--flame)"
const EMBER = "var(--ember)"
const SPARK = "var(--spark)"
const LINE = "rgba(255,255,255,0.14)"
const DIM = "rgba(255,255,255,0.45)"

/** A fact, with the fifth slot lit. Provenance is a column, not a convention. */
export function ProvenanceIllustration() {
  const cols = [
    { label: "id", w: 54 },
    { label: "attribute", w: 84 },
    { label: "value", w: 60 },
    { label: "tx", w: 38 },
  ]
  let x = 8

  return (
    <svg viewBox="0 0 300 150" className="w-full max-w-[340px]" aria-hidden="true">
      <rect x="4" y="34" width="292" height="44" rx="6" fill="none" stroke={LINE} />
      {cols.map((c) => {
        const at = x
        x += c.w
        return (
          <g key={c.label}>
            <text x={at + 8} y={61} fill={DIM} fontSize="11" fontFamily="ui-monospace, monospace">
              {c.label}
            </text>
            <line x1={at + c.w} y1="34" x2={at + c.w} y2="78" stroke={LINE} />
          </g>
        )
      })}

      {/* The fifth slot, and the only one that glows. */}
      <rect x={x} y="34" width={296 - x} height="44" rx="6" fill={EMBER} fillOpacity="0.14" />
      <text x={x + 10} y={61} fill={EMBER} fontSize="11" fontFamily="ui-monospace, monospace">
        by
      </text>

      <path
        d={`M ${x + 26} 92 L ${x + 26} 108 L 150 108`}
        fill="none"
        stroke={EMBER}
        strokeOpacity="0.5"
        strokeDasharray="3 3"
      />
      <rect x="58" y="112" width="184" height="26" rx="6" fill="none" stroke={EMBER} strokeOpacity="0.5" />
      <text x="150" y="129" fill={EMBER} fontSize="11" textAnchor="middle" fontFamily="ui-monospace, monospace">
        what produced it
      </text>

      <text x="150" y="22" fill={DIM} fontSize="11" textAnchor="middle" fontFamily="ui-monospace, monospace">
        one row, five slots
      </text>
    </svg>
  )
}

/** The fence. One side has a door; the other has no way to reach at all. */
export function FenceIllustration() {
  return (
    <svg viewBox="0 0 300 150" className="w-full max-w-[340px]" aria-hidden="true">
      <rect x="4" y="20" width="140" height="112" rx="8" fill="none" stroke={LINE} />
      <text x="74" y="42" fill={DIM} fontSize="11" textAnchor="middle" fontFamily="ui-monospace, monospace">
        formula
      </text>
      {["no clock", "no network", "no files"].map((t, i) => (
        <text
          key={t}
          x="74"
          y={66 + i * 18}
          fill="rgba(255,255,255,0.3)"
          fontSize="10"
          textAnchor="middle"
          fontFamily="ui-monospace, monospace"
        >
          {t}
        </text>
      ))}

      <rect x="156" y="20" width="140" height="112" rx="8" fill="none" stroke={FLAME} strokeOpacity="0.45" />
      <text x="226" y="42" fill={FLAME} fontSize="11" textAnchor="middle" fontFamily="ui-monospace, monospace">
        job
      </text>
      <text x="226" y="66" fill={DIM} fontSize="10" textAnchor="middle" fontFamily="ui-monospace, monospace">
        http
      </text>
      <text x="226" y="84" fill={DIM} fontSize="10" textAnchor="middle" fontFamily="ui-monospace, monospace">
        a cadence
      </text>

      {/* The door, and the wall. */}
      <path d="M 288 76 L 300 76" stroke={FLAME} strokeWidth="2" strokeLinecap="round" />
      <path d="M 226 100 L 226 126" stroke={FLAME} strokeOpacity="0.6" strokeDasharray="3 3" />
      <text x="226" y="140" fill={FLAME} fontSize="10" textAnchor="middle" fontFamily="ui-monospace, monospace">
        the world
      </text>

      <path d="M 74 100 L 74 126" stroke={LINE} strokeDasharray="3 3" />
      <g stroke="rgba(255,255,255,0.25)">
        <line x1="66" y1="132" x2="82" y2="146" />
        <line x1="82" y1="132" x2="66" y2="146" />
      </g>
    </svg>
  )
}

/** An edge is a fact whose value is another id. Nothing else to model. */
export function GraphIllustration() {
  return (
    <svg viewBox="0 0 300 150" className="w-full max-w-[340px]" aria-hidden="true">
      <line x1="76" y1="60" x2="224" y2="60" stroke={SPARK} strokeOpacity="0.4" />
      <line x1="76" y1="60" x2="150" y2="120" stroke={LINE} />

      <circle cx="76" cy="60" r="20" fill="none" stroke={SPARK} strokeOpacity="0.7" />
      <text x="76" y="64" fill={SPARK} fontSize="10" textAnchor="middle" fontFamily="ui-monospace, monospace">
        ada
      </text>

      <circle cx="224" cy="60" r="20" fill="none" stroke={SPARK} strokeOpacity="0.7" />
      <text x="224" y="64" fill={SPARK} fontSize="10" textAnchor="middle" fontFamily="ui-monospace, monospace">
        grace
      </text>

      <rect x="128" y="108" width="44" height="24" rx="4" fill="none" stroke={LINE} />
      <text x="150" y="124" fill={DIM} fontSize="10" textAnchor="middle" fontFamily="ui-monospace, monospace">
        180
      </text>

      <text x="150" y="52" fill={SPARK} fontSize="10" textAnchor="middle" fontFamily="ui-monospace, monospace">
        friend
      </text>
      <text x="98" y="100" fill={DIM} fontSize="10" textAnchor="middle" fontFamily="ui-monospace, monospace">
        height
      </text>

      <text x="150" y="20" fill={DIM} fontSize="11" textAnchor="middle" fontFamily="ui-monospace, monospace">
        an edge is a fact
      </text>
    </svg>
  )
}
