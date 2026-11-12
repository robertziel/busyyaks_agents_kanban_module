// Monochrome 16px stroke icons for the board (currentColor; .ico in kanban.css).
const PATHS = {
  user: "M8 8a2.6 2.6 0 1 0 0-5.2A2.6 2.6 0 0 0 8 8zM3 13.5c.6-2.4 2.6-3.7 5-3.7s4.4 1.3 5 3.7",
  tag: "M2.5 2.5h5.2l5.8 5.8-5.2 5.2-5.8-5.8zM5.3 5.3h.01",
  check: "M2.5 2.5h11v11h-11zM5 8.2l2 2 4-4.4",
  clock: "M8 14A6 6 0 1 0 8 2a6 6 0 0 0 0 12zM8 4.8V8l2.2 1.4",
  cover: "M2.5 3h11v10h-11zM2.5 7h11",
  link: "M6.8 9.2a2.5 2.5 0 0 0 3.5 0l2.2-2.2a2.5 2.5 0 0 0-3.5-3.5l-.8.8M9.2 6.8a2.5 2.5 0 0 0-3.5 0L3.5 9a2.5 2.5 0 0 0 3.5 3.5l.8-.8",
  archive: "M2 3h12v3H2zM3 6v7h10V6M6.5 9h3",
  desc: "M3 4h10M3 7h10M3 10h7",
  comment: "M2.5 3h11v7.5H6.5L3.5 13v-2.5h-1z",
  activity: "M2 8h3l2-4 2 8 2-4h3",
  list: "M6 4h8M6 8h8M6 12h8M2.5 4h.01M2.5 8h.01M2.5 12h.01",
  dots: "M3.5 8h.01M8 8h.01M12.5 8h.01",
  eye: "M1.5 8S4 3.5 8 3.5 14.5 8 14.5 8 12 12.5 8 12.5 1.5 8 1.5 8zM8 10a2 2 0 1 0 0-4 2 2 0 0 0 0 4z",
  clip: "M14.3 7.4 8.2 13.5a4 4 0 0 1-5.7-5.7l6.1-6.1a2.7 2.7 0 0 1 3.8 3.8L6.3 11.6a1.3 1.3 0 0 1-1.9-1.9l5.7-5.6",
  download: "M8 2.5v8M4.8 7.6 8 10.8l3.2-3.2M3 13.5h10",
  file: "M4 1.8h5l3 3v9.4H4zM9 1.8v3h3",
  chevLeft: "M9.8 3.6 5.4 8l4.4 4.4",
  chevRight: "M6.2 3.6 10.6 8l-4.4 4.4",
} as const;

export type IconName = keyof typeof PATHS;

export function KbIcon({ name, title }: { name: IconName; title?: string }) {
  return (
    <svg className="ico" viewBox="0 0 16 16" aria-hidden={title ? undefined : true} role={title ? "img" : undefined}>
      {title && <title>{title}</title>}
      <path d={PATHS[name]} />
    </svg>
  );
}
