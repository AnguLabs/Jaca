import math

S = 1024
# macOS icon grid: 824 content centered in 1024, corner radius ~185
m = 100; side = S - 2*m; r = 185
cx, cy = S/2, S/2 + 6

def wedges(cx, cy, rad, n, gap_deg, fill):
    out = []
    step = 360.0/n
    for i in range(n):
        a0 = math.radians(i*step + gap_deg/2 - 90)
        a1 = math.radians((i+1)*step - gap_deg/2 - 90)
        x0, y0 = cx + rad*math.cos(a0), cy + rad*math.sin(a0)
        x1, y1 = cx + rad*math.cos(a1), cy + rad*math.sin(a1)
        out.append(f'<path d="M {cx:.1f} {cy:.1f} L {x0:.1f} {y0:.1f} '
                   f'A {rad:.1f} {rad:.1f} 0 0 1 {x1:.1f} {y1:.1f} Z" fill="{fill}"/>')
    return "\n".join(out)

R_rind  = 300     # white rind outer
R_flesh = 268     # pale membrane disc
R_seg   = 250     # white segments (membranes show as gaps)
R_core  = 30

svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="{S}" height="{S}" viewBox="0 0 {S} {S}">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0"   stop-color="#FFDE45"/>
      <stop offset="0.55" stop-color="#FFC01E"/>
      <stop offset="1"   stop-color="#FB9000"/>
    </linearGradient>
    <linearGradient id="gloss" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.35"/>
      <stop offset="0.4" stop-color="#FFFFFF" stop-opacity="0"/>
    </linearGradient>
    <linearGradient id="leaf" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#5BD074"/>
      <stop offset="1" stop-color="#2BA84A"/>
    </linearGradient>
    <filter id="soft" x="-30%" y="-30%" width="160%" height="160%">
      <feDropShadow dx="0" dy="10" stdDeviation="16" flood-color="#7A3D00" flood-opacity="0.28"/>
    </filter>
    <radialGradient id="flesh" cx="0.5" cy="0.42" r="0.65">
      <stop offset="0" stop-color="#FFF7DA"/>
      <stop offset="1" stop-color="#FFE39A"/>
    </radialGradient>
  </defs>

  <!-- squircle -->
  <rect x="{m}" y="{m}" width="{side}" height="{side}" rx="{r}" ry="{r}" fill="url(#bg)"/>
  <rect x="{m}" y="{m}" width="{side}" height="{side}" rx="{r}" ry="{r}" fill="url(#gloss)"/>

  <!-- leaf (behind the lemon, peeking top-right) -->
  <g transform="rotate(-32 {cx} {cy})" filter="url(#soft)">
    <path d="M {cx+150} {cy-300} C {cx+330} {cy-300} {cx+360} {cy-150} {cx+250} {cy-70}
             C {cx+150} {cy-150} {cx+150} {cy-230} {cx+150} {cy-300} Z" fill="url(#leaf)"/>
    <path d="M {cx+180} {cy-270} C {cx+250} {cy-210} {cx+250} {cy-150} {cx+245} {cy-95}"
          stroke="#FFFFFF" stroke-opacity="0.45" stroke-width="9" fill="none" stroke-linecap="round"/>
  </g>

  <!-- cut lemon -->
  <g filter="url(#soft)">
    <circle cx="{cx}" cy="{cy}" r="{R_rind}" fill="#FFFFFF"/>
    <circle cx="{cx}" cy="{cy}" r="{R_flesh}" fill="url(#flesh)"/>
    {wedges(cx, cy, R_seg, 10, 7, "#FFFFFF")}
    <circle cx="{cx}" cy="{cy}" r="{R_core}" fill="#FFFFFF"/>
    <circle cx="{cx}" cy="{cy}" r="{R_flesh}" fill="none" stroke="#FFD66B" stroke-opacity="0.5" stroke-width="3"/>
  </g>

  <!-- squeeze droplet -->
  <path d="M {cx} {cy+330} C {cx+44} {cy+392} {cx+44} {cy+430} {cx} {cy+438}
           C {cx-44} {cy+430} {cx-44} {cy+392} {cx} {cy+330} Z"
        fill="#FFFFFF" filter="url(#soft)"/>
</svg>'''
open("/tmp/squeeze_icon.svg","w").write(svg)
print("svg written")
