// agents_kanban/react — the board for a React 18 host. The host renders <Board api={…} me={…} slug={…} view={…}
// onView={…} /> with its own KanbanApi (api.ts) and loads styles/kanban.css (+ styles/base.css when it has no .btn /
// .tag / .flash primitives of its own). Everything else below is what a host may reuse: the board's pure logic,
// the summary helpers and the types of the JSON the engine sends.
export { Board, type BoardProps, type BoardView } from "./components/Board";
export { CardDialog, PANELS, type Panel } from "./components/CardDialog";
export { MarkdownEditor, UploadChips, type Upload } from "./components/MarkdownEditor";
export { KbIcon, type IconName } from "./components/KbIcon";
export { Select, type Option } from "./components/Select";
export { BoardEditor } from "./components/BoardEditor";
export { CardLinkRow, CardLinks, LINK_KIND } from "./components/CardLinkRow";
export { Avatar, AgentLinks, CopyChip, ErrorState, Html, Loading, sessionFor } from "./components/Bits";
export { KanbanHostProvider, useKanbanHost, colLabel, type KanbanHostValue } from "./host";
export { LaunchBar, type LaunchBarProps } from "./components/LaunchBar";
export { errMsg, KanbanApiError, type KanbanApi, type LaunchApi, type CardPatch } from "./api";
export * from "./lib/launch";
export * from "./types";
export * from "./lib/board";
export * from "./lib/workflow";
export * from "./lib/graph";
export * from "./lib/card";
export * from "./lib/links";
export * from "./lib/listen";
export * from "./lib/attachments";
export { useLiveRev, type LiveState } from "./lib/live";
export { useFetch, type Resource } from "./lib/fetch";
export { ago, at, isoAgo, isoAt, initials, hue, now } from "./lib/format";
