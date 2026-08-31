import math

# --- geometry copied verbatim from ic_launcher_foreground.xml -------------
CONE = [(32,46),(43,46),(58,31),(58,77),(43,62),(32,62)]
# SVG elliptical arcs: (start, end, radius, sweep)
ARCS = [((66,42),(66,66),14,1),
        ((75,33),(75,75),25,1)]
SAFE = (18,18,90,90)          # 72x72 adaptive-icon safe zone
STROKE = 5

def arc_center(p1,p2,r,sweep):
    (x1,y1),(x2,y2)=p1,p2
    mx,my=(x1+x2)/2,(y1+y2)/2
    dx,dy=x2-x1,y2-y1
    d=math.hypot(dx,dy)/2
    h2=r*r-d*d
    if h2<0: raise SystemExit(f"IMPOSSIBLE ARC: r={r} too small for chord {d*2:.1f}")
    h=math.sqrt(h2)
    ux,uy=dx/(2*d),dy/(2*d)
    px,py=-uy,ux                       # perpendicular
    # For large-arc=0, the centre sits on the side OPPOSITE the bulge, which for
    # sweep=1 (clockwise on a y-down canvas) is +perp where perp=(-uy,ux).
    # Getting this backwards selects the major arc and reports phantom overflow.
    s = 1 if sweep else -1
    return (mx+s*h*px, my+s*h*py), h

def in_poly(x,y,poly):
    c=False; n=len(poly)
    for i in range(n):
        x1,y1=poly[i]; x2,y2=poly[(i+1)%n]
        if (y1>y)!=(y2>y):
            xi=x1+(y-y1)*(x2-x1)/(y2-y1)
            if x<xi: c=not c
    return c

def on_arc(x,y,p1,p2,r,sweep):
    (cx,cy),_=arc_center(p1,p2,r,sweep)
    if abs(math.hypot(x-cx,y-cy)-r)>STROKE/2: return False
    a  = math.atan2(y-cy,x-cx)
    a1 = math.atan2(p1[1]-cy,p1[0]-cx)
    a2 = math.atan2(p2[1]-cy,p2[0]-cx)
    # sweep=1 -> increasing angle from a1 to a2
    span=(a2-a1)%(2*math.pi); rel=(a-a1)%(2*math.pi)
    return rel<=span

print("foreground layer, '#'=cone  '*'=waves  '.'=safe-zone edge\n")
minx=miny=999; maxx=maxy=-999
for y in range(0,108,3):
    row=""
    for x in range(0,108,2):
        ch=" "
        if in_poly(x,y,CONE): ch="#"
        else:
            for a in ARCS:
                if on_arc(x,y,*a): ch="*"; break
        if ch!=" ":
            minx=min(minx,x); maxx=max(maxx,x); miny=min(miny,y); maxy=max(maxy,y)
        if ch==" " and (x in (SAFE[0],SAFE[2]) or y in (SAFE[1],SAFE[3])): ch="."
        row+=ch
    print(row)

print(f"\nink bounds      x {minx}..{maxx}   y {miny}..{maxy}")
print(f"safe zone       x {SAFE[0]}..{SAFE[2]}   y {SAFE[1]}..{SAFE[3]}")
ok = minx>=SAFE[0] and maxx<=SAFE[2] and miny>=SAFE[1] and maxy<=SAFE[3]
print("safe-zone fit   " + ("OK - nothing clips under a circular mask"
                            if ok else "*** ARTWORK EXCEEDS SAFE ZONE ***"))
for i,a in enumerate(ARCS):
    (cx,cy),h = arc_center(*a)
    print(f"arc {i+1}          centre ({cx:.1f},{cy:.1f})  bulges to x={cx+a[2]:.1f}")
