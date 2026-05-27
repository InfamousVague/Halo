# Halo — Visual identity & asset prompts

Halo's icon and showcase art live in the same MattsSoftware
suite family as Alfred (butler), Espresso (barista cup),
Worktree (sapling), Port (sailor), Uninstaller (sanitation
worker), etc.: glossy Pixar/Apple-style soft-vinyl figurines
with rosy cheeks, three-point studio lighting, brand-colour
squircle for the app icon, transparent PNG hero for the site
/ launcher card.

Halo's metaphor is the **halo over the MacBook notch** — a
small celestial-watcher character cradling the Dynamic Island
in their hands.

---

## 1. Brand colour

Halo's palette is a warm **champagne-gold**, distinct from
Espresso's coffee-orange (`#FFB27A → #E09060`) and
Quarantine's amber (`#F7D05C → #C89212`). Reads as "sunlight
catching the rim of something" rather than "espresso crema"
or "danger amber."

| Role                  | Hex       | Note                                     |
| --------------------- | --------- | ---------------------------------------- |
| Primary brand colour  | `#F5BD5C` | The halo gold itself                     |
| Squircle gradient TL  | `#FFD988` | Top-left of the app-icon squircle        |
| Squircle gradient BR  | `#DDA84A` | Bottom-right of the app-icon squircle    |
| Cream wash backdrop   | `#FAEFD2` | Hero illustration wash (alt: transparent) |
| Soft-glow accent      | `#FFE9B0` | The character's halo ring inner-glow      |
| Deep shadow accent    | `#8A5E18` | Optional rim under dropshadow             |

Update `Halo.app/Contents/Resources/AppIcon.icns`,
`mattssoftware-launcher/.../Resources/Assets.xcassets/halo.imageset/`,
and `mattssoftware/public/halo/app-icon.png` once the icon
renders.

---

## 2. Character continuity

**Hero:** a chibi 3D **guardian angel** character, plump and
friendly, with a soft glowing **halo ring** floating an inch
above their head. Reads warm and cute, never religious or
stern — closer to a Pixar "celestial intern" than a renaissance
cherub. Their job: cradling the Mac's Dynamic Island in cupped
palms so they can show the user whatever it has to say.

| Trait        | Spec                                                                                   |
| ------------ | -------------------------------------------------------------------------------------- |
| Body         | Chubby Pixar proportions, big round head, stubby arms, small bare feet                  |
| Skin         | Soft warm cream `#FCEBD0`, slight rosy cheeks                                          |
| Hair         | Soft cream-blond, gentle waves under the halo                                          |
| Eyes         | Big closed-crescent smile eyes (kawaii), or wide round chocolate-brown                |
| Halo ring    | Glossy champagne-gold ring `#F5BD5C` with `#FFE9B0` inner glow, floats ~1cm above hair |
| Wings        | Two small fluffy white wing-puffs folded behind, like marshmallow pillows              |
| Wardrobe     | Snug sleeveless cream-and-gold tunic, soft gold trim at neckline and hem               |
| Hand prop    | A miniature Dynamic Island — a tiny **glossy-black pill** with the camera notch cut into the top edge — cradled between cupped palms, glowing softly with `#FFE9B0` inner light |
| Pose         | Centred, gentle smile, looking down at the pill in their hands with soft fondness     |
| Materials    | Soft-vinyl figurine glossy finish, painted highlights on cheeks / nose / halo metal   |

Optional emblem letter for 32×32 favicon legibility: a small
gold `H` embroidered on the tunic chest. Keeps the icon
readable when shrunk to a menu-bar tile.

---

## 3. Prompt — App icon (1024×1024)

Paste into Lovart / Nanobanana / Midjourney with `--ar 1:1`:

> A cute Pixar-style **chibi 3D guardian-angel character**,
> glossy soft-vinyl figurine aesthetic, plump and friendly.
> Soft cream skin (`#FCEBD0`) with rosy cheeks and a tiny gold
> "H" emblem embroidered on a snug sleeveless **cream-and-gold
> tunic** (warm cream body, glossy gold trim at neckline and
> hem matching brand colour `#F5BD5C`). Cream-blond hair in
> soft waves. **A glossy champagne-gold halo ring** (`#F5BD5C`,
> polished metal) floats an inch above the head, glowing softly
> from within (`#FFE9B0` inner glow, gentle bloom). Two small
> fluffy white **wing-puffs** peek out behind the shoulders,
> like marshmallow pillows. Cradled between the angel's
> **cupped palms at chest level**: a miniature Dynamic Island —
> a small **glossy-black pill** with a tiny camera-notch
> cut into its top edge — glowing softly with warm gold inner
> light (`#FFE9B0`), like the angel is showing the viewer
> something precious. The angel looks **down at the pill in
> their hands** with a soft contented smile (closed-crescent
> kawaii eyes), as if mid-blessing. Centred in frame, full body
> visible from bare feet to halo. Three-point Pixar/Apple
> studio lighting: warm gold key from upper-left, soft
> champagne rim along the right edge of the figure, gentle
> cream bounce from below. Subtle drop-shadow grounding the
> character. **Background**: smooth radial-gradient
> **rounded-square (squircle)** — `#FFD988` warm gold in the
> upper-left fading to `#DDA84A` deeper gold in the lower-right
> — subtle inner-gloss highlight along the top edge of the
> squircle. Composition tight, character fills ~70% of the
> squircle vertically, centred. Same visual family as the
> MattsSoftware suite icons (**Alfred** butler, **Espresso**
> barista cup, **Worktree** sapling, **Port** sailor,
> **Uninstaller** sanitation worker). **1024×1024 PNG**, no
> border, **no text** other than the small `H` emblem on the
> tunic chest.
>
> **Exclude:** any letters/numbers/UI screenshots/logos beyond
> the single "H" emblem; photorealism; harsh shadows; religious
> iconography (no crosses, no stained glass, no stern poses);
> halo as a flat 2D ring (must read as a polished 3D metal
> torus); flat illustration style; cartoon style; opaque
> non-gold backgrounds.

---

## 4. Prompt — Hero illustration (1600×1200, transparent)

For the site's `public/halo/hero.png` and launcher card detail:

> Same **chibi guardian-angel character** from the Halo app
> icon — full body, **three-quarter view**, standing relaxed on
> a transparent backdrop. Cream-blond hair under a glossy
> champagne-gold halo ring (`#F5BD5C`, with `#FFE9B0` inner
> glow), small white wing-puffs folded behind, snug
> sleeveless cream-and-gold tunic with a tiny gold `H` emblem
> on the chest, soft cream skin, rosy cheeks. The angel
> **holds a miniature MacBook Pro at chest level**, tilted
> slightly forward so the **notch + Dynamic Island pill** at
> the top of the screen is the focal point: a small
> **glossy-black rounded pill** hanging from the screen edge
> with a tiny camera-notch cut-out, glowing softly with warm
> gold inner light (`#FFE9B0`). Coming out of the pill, **two
> tiny floating "live activity" cards**: one shows a small
> espresso-cup glyph, the other a small music-note — they hover
> half a centimetre off the screen like AR overlays, soft glow
> trailing under each. The angel looks **down at the laptop's
> notch** with a soft proud smile (closed-crescent eyes). Soft
> global Pixar lighting like the rest of the suite hero shots
> — warm key from upper-left, gentle champagne rim, subtle
> shadow under bare feet, no environment. **1600×1200 PNG,
> transparent alpha** (no background squircle, no desk surface,
> no environment — just the angel + laptop + glowing pill on
> a clean alpha channel). Centred character on transparent
> backdrop, ~80% of frame vertically. Matches the playful-3D
> style of Alfred's butler-with-silver-tray and Uninstaller's
> sanitation-worker-with-trash-bag illustrations.
>
> **Exclude:** any text on screens (notch pill must look like
> a glossy abstract pill, not a UI screenshot with words),
> letterforms beyond the "H" emblem, watermarks, photorealism,
> flat illustration style, opaque backdrop, desk / table /
> ground plane, environment props, religious iconography.

---

## 5. Prompt — Showcase / banner scene (2400×1200, optional)

A wider "in their workshop" scene for site banners or social
cards:

> Wide cinematic shot, **same chibi guardian-angel character**
> from the Halo icon, **three-quarter view**, perched
> cross-legged on a **floating champagne-gold cloud** that
> drifts above an open MacBook. The MacBook sits in the lower
> third of the frame; the angel hovers above its open lid,
> bare feet tucked, both hands gesturing toward the
> **Dynamic Island pill at the top of the screen** like a tour
> guide pointing at a small precious specimen. **Four tiny
> floating "live activity" cards** orbit slowly around the
> notch in a soft arc — an espresso-cup, a music-note, a
> calendar tile, a battery icon — each glowing in its own
> brand colour with a faint trail behind, like little
> notification fireflies. The halo above the angel's head
> glows with `#FFE9B0` warm inner light, casting a soft
> champagne tint on the MacBook keyboard below. Soft global
> Pixar lighting, subtle volumetric god-rays from upper-left,
> cream haze in the background fading to transparent at the
> edges. **2400×1200 PNG, transparent alpha** (no environment,
> just the floating composition). Composition reads
> left-to-right: angel + cloud upper-left, MacBook lower-right,
> activity-cards arcing between. Premium Pixar/Apple
> illustration polish.
>
> **Exclude:** text/letterforms (cards are pure glyph-on-tile,
> no words), photorealism, flat illustration, opaque backdrop,
> desk, room, religious iconography, ground plane.

---

## 6. Where the rendered assets land

Once the icon renders cleanly:

| File                                                                                                                       | What goes there                                |
| -------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------- |
| `halo-swift/art/AppIcon-source.png`                                                                                        | 1024×1024 master PNG from §3                   |
| `halo-swift/Halo.app/Contents/Resources/AppIcon.icns`                                                                      | Generated by `make-app.sh` from the source PNG |
| `mattssoftware-launcher/Sources/MattsSoftwareMenuBar/Resources/Assets.xcassets/halo.imageset/halo.png`                     | Same 1024×1024 (or 512px / 1024px @1x/@2x)     |
| `mattssoftware/public/halo/app-icon.png`                                                                                   | 1024×1024 from §3                              |
| `mattssoftware/public/halo/hero.png`                                                                                       | 1600×1200 transparent from §4                  |
| `mattssoftware/public/halo/banner.png`                                                                                     | 2400×1200 transparent from §5 (optional)       |

Halo is **already** registered in the launcher catalog at
`mattssoftware-launcher/.../Catalog.swift` (`id: "halo"`,
`iconAsset: "halo"`) so dropping `halo.imageset` into the
launcher's asset catalog is enough to light up the launcher
tile.

The site needs i18n strings + a `public/halo/` directory; the
copy below feeds into that.

---

## 7. Site / launcher copy

| Slot              | Copy                                                                                                                |
| ----------------- | ------------------------------------------------------------------------------------------------------------------- |
| Tagline (launcher catalog, already set) | _Dynamic Island for your MacBook notch — every suite app's live activity._                                                 |
| One-liner (site card) | _A live, glanceable status pill hanging from your Mac's notch._                                                          |
| About paragraph   | _Halo turns the notch on your MacBook into a Dynamic Island. Volume, brightness, AirPods battery, what's playing — all live, all in one place. Other MattsSoftware apps (Espresso's keep-awake timer, Worktree's current branch, Port's listening-ports count, Peephole's camera/mic activity) publish to it too, so the things you actually care about share one small pill at the top of the screen instead of scattering across the menu bar._ |
| Feature bullets   | • Lives in the notch — out of the way until it has something to say.<br>• Built-in publishers for volume, brightness, AirPods battery, Stats, Now Playing, Calendar, GitHub PRs, Docker, VPN, Battery.<br>• Reads suite-wide live-activity payloads so every other MattsSoftware app shows up automatically.<br>• Hover to expand, click to cycle, tap-to-cycle pause / reset on hover.<br>• Per-app brand tint, slot-machine digit animations, marquee track titles. |
| Permissions       | _Bluetooth (AirPods battery only — read advertisements, never pair). AppleEvents (Spotify / Music / browsers — read current track). Calendar (read-only, next event countdown)._ |
