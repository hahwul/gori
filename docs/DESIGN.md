# Documentation design

This document records the design contract for the gori documentation site. It complements the product architecture in `.github/DESIGN.md`; it does not redefine gori's runtime behavior.

## Direction

The site should feel like gori before a reader reaches the first command. Its visual language comes from the TUI: compact labels, precise dividers, keyboard cues, status-like metadata, and restrained terminal framing. The result must still read as editorial documentation rather than a terminal replica.

The gori logo and the existing gold, indigo, cream, and near-black palette remain the brand anchors. Layout, type scale, rhythm, navigation, and illustration may be more experimental, provided that body text, code, tables, focus states, and headings remain immediately readable.

The implementation stays native to Hwaro: Crinja templates, the existing Markdown processor, and local CSS and JavaScript. It adds no frontend framework or runtime dependency.

## Information architecture

The current build contains 90 pages across English and Korean. Each language has 16 Guide articles and 12 Playbook chapters, plus their section covers. Both languages must expose the same page set and ordering.

General documentation uses a compact manual navigation:

- Getting Started contains four ordered pages and expands when active.
- Guide exposes its overview and four topic groups. Only the group containing the current page expands.
- Reference contains eight ordered pages and expands when active.
- Playbooks appears as a prominent link to a separate field guide, without placing its 12 chapters in the general sidebar.

Playbooks has its own book context. The section index acts as a cover, shows all chapters grouped into four parts, and explains how to work through them. Chapter pages use a numbered table of contents, open the current part, and provide a route back to the general Guide.

Existing public paths remain unchanged, including every `/guide/`, `/playbooks/`, `/reference/`, and `/ko/` URL. English and Korean remain first-class variants rather than one language falling back to the other.

## Content metadata

Front matter is the single source of truth for both catalogs and navigation:

- `weight` defines page and chapter order.
- `extra.group` defines the Guide topic or Playbook part.
- The group value is localized (`Core` / `핵심`, for example), while matching weights keep the language variants aligned.

This metadata is the most fragile part of the design. A missing group can create a blank navigation part, and duplicate or drifting weights can reorder translations differently. Guide and Playbook archetypes therefore include an explicit weight and a valid default group. Every new EN/KO pair must use corresponding weights and a valid localized group name.

Section landing pages must not maintain a second hand-written page list. Hwaro templates build those catalogs from the same metadata, preventing the landing page, sidebar, and book contents from drifting apart.

## Readability and motion

Body copy and code remain the visual priority. Experimental treatments belong in navigation, covers, dividers, figures, and metadata rather than behind long-form text. Line length, contrast, heading hierarchy, table overflow, and code wrapping must work before decorative effects are added.

Motion should be short, low-amplitude, and informative: revealing a section, acknowledging a state change, or orienting the reader. The site must honor `prefers-reduced-motion`, must not hide content without JavaScript, and must not require animation to understand state.

The landing is the one place that is art before it is documentation: eight screens of one viewport each on native `scroll-snap`, so the wheel turns a page rather than scrolling one, and one fixed canvas behind them (`static/js/home-art.js`) that paints every scene as an ordered-dither field in four inks (`--art-0..3` on `body.is-home`, swapped per theme). The scenes are the ring knot approaching, the loop with packets on it, a History table raining past five figures, the TUI captures as a film strip, the MCP seam, the name set as pixel Hangul, and the wallpaper's clouds under the install line. Chapters crossfade in luminance under the dither, which is what makes one screen dissolve into dots and re-form as the next. The DOM holds only the words, so a no-script visit reads as eight plain screens, and under `prefers-reduced-motion` the field is still drawn but without the ambient drift, the eased dissolve or the glyph decode. The labels use a self-hosted Latin subset of DotGothic16 (`static/fonts`, OFL) over the mono stack; Hangul labels fall through to the system face. Elsewhere the knot appears as a still `<pre>` (`templates/partials/glyph-knot.html`, generated from `static/images/gori.png` at 22 rows): on the Playbooks cover and the 404 page. Section openers across the doc pages share one voice, a numbered mono-caps rail on a hairline (the catalog group headings on section covers).

Keyboard and screen-reader behavior is part of the design. Native links, buttons, `details`/`summary`, visible focus, `aria-current`, a skip link, and a logical heading order take precedence over custom interaction.

## Validation

Before merging documentation design changes:

1. Run `hwaro build -i docs` and confirm all 90 content pages render without template or front-matter errors.
2. Run `hwaro serve -i docs` and inspect the generated site in a browser at narrow mobile, tablet, laptop, and wide desktop viewports.
3. Check light and dark themes, English and Korean, long titles, code blocks, tables, and pages with deep heading trees.
4. Verify the compact manual navigation, active Guide group, Playbook cover, chapter numbering, current Playbook part, mobile navigation toggle, previous/next paths, and the return to Guide.
5. Follow internal links and retained anchors, especially section index anchors such as `#topics`, `#contents`, and `#next-steps`.
6. Confirm search finds pages in both languages and opens the correct localized URL.
7. Navigate header, search, sidebar, theme control, language control, and page contents using only the keyboard; verify visible focus and current-page state.
8. Test with JavaScript disabled and with reduced motion enabled. Core content and navigation must remain usable.

If page counts or the Guide and Playbook chapter counts change, update this document and verify that both languages changed together.
