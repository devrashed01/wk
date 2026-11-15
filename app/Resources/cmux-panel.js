// wk panel for cmux: the current task's note, git state and setup progress, plus every
// workspace with its note. Installed by wk (Settings → cmux) as ~/.config/cmux/sidebars/wk.js.
// Show it with: cmux right-sidebar set custom wk
// wk://… links open the wk app (note editor, task list, new task).

const enc = (s) => encodeURIComponent(String(s ?? ""));
const wk = (route, w) => openURL("wk://" + route + (w ? "?path=" + enc(w.directory) : ""));

const AGENT = {
  needs_input: { color: "#FF9F0A", label: "needs you" },
  working: { color: "#0A84FF", label: "working" },
  idle: { color: "#34C759", label: "idle" },
};

function agentSummary(w) {
  const live = (w.agents ?? []).filter((a) => AGENT[a.status]);
  if (live.length === 0) return "";
  const first = live.find((a) => a.status === "needs_input") ?? live.find((a) => a.status === "working") ?? live[0];
  return "Claude " + AGENT[first.status].label + (live.length > 1 ? " +" + (live.length - 1) : "");
}

function agentColor(w) {
  const live = (w.agents ?? []).filter((a) => AGENT[a.status]);
  const first = live.find((a) => a.status === "needs_input") ?? live.find((a) => a.status === "working") ?? live[0];
  return first ? AGENT[first.status].color : "clear";
}

function gitLine(w) {
  const bits = [];
  if (w.branch) bits.push(w.branch + (w.dirty ? " ●" : ""));
  if (w.pr) bits.push("PR #" + w.pr.number + " " + (w.pr.status ?? ""));
  return bits.join("  ·  ");
}

const selected = computed(() => (data.workspaces() ?? []).find((w) => w.selected) ?? null);

// One flat keyed list; the kind is part of the key so each template stays put across updates.
const entries = computed(() => {
  const out = [];
  const current = selected();
  if (current) {
    out.push({ key: "title", kind: "title", w: current });
    out.push({ key: "note", kind: "note", w: current });
    if (gitLine(current)) out.push({ key: "git", kind: "git", w: current });
    if (current.progress) out.push({ key: "progress", kind: "progress", w: current });
    if (agentSummary(current)) out.push({ key: "agent", kind: "agent", w: current });
    out.push({ key: "actions", kind: "actions", w: current });
  }
  out.push({ key: "others", kind: "section", text: "Workspaces" });
  for (const w of data.workspaces() ?? []) out.push({ key: "w:" + w.id, kind: "row", w });
  return out;
});

const button = (label, onTap) =>
  Text(label)
    .font(11).weight("medium")
    .lineLimit(1).fixedSize()
    .paddingHorizontal(9).paddingVertical(4)
    .cornerRadius(6)
    .background("#7f7f7f24")
    .hoverBackground("#7f7f7f44")
    .cursor("pointer")
    .onTap(onTap);

function view(entry) {
  const w = () => entry().w;
  switch (entry().kind) {
    case "title":
      return HStack({ spacing: 8 }, [
        RoundedRectangle({ cornerRadius: 2 }).fill(() => w().color ?? "#7f7f7f55").frame({ width: 4, height: 18 }),
        Text(() => w().title).font(15).weight("semibold").lineLimit(1).truncation("tail"),
        Spacer(),
      ]).paddingHorizontal(10).paddingTop(4);
    case "note":
      return HStack([
        Text(() => w().description || "Add a note…")
          .font(13)
          .color(() => (w().description ? "primary" : "tertiary"))
          .lineLimit(6),
        Spacer(),
      ])
        .padding(10)
        .background("#7f7f7f17")
        .cornerRadius(8)
        .hoverBackground("#7f7f7f2a")
        .cursor("pointer")
        .onTap(() => wk("note", w()))
        .paddingHorizontal(10);
    case "git":
      return Text(() => gitLine(w()))
        .font(11).monospaced().color("secondary").lineLimit(1).truncation("middle")
        .paddingHorizontal(10)
        .frame({ maxWidth: "infinity", alignment: "leading" })
        .cursor("pointer")
        .onTap(() => { if (w().pr?.url) openURL(w().pr.url); });
    case "progress":
      return HStack({ spacing: 6 }, [
        Text("⏳").font(11),
        Text(() => (w().progress?.label || "Working") + "  " + Math.round((w().progress?.value ?? 0) * 100) + "%")
          .font(11).color("#F59E0B").lineLimit(1).truncation("tail"),
        Spacer(),
      ]).paddingHorizontal(10);
    case "agent":
      return HStack({ spacing: 6 }, [
        Circle({ size: 7 }).fill(() => agentColor(w())),
        Text(() => agentSummary(w())).font(11).color("secondary"),
        Spacer(),
      ]).paddingHorizontal(10);
    case "actions":
      return HStack({ spacing: 6 }, [
        button("Edit note", () => wk("note", w())),
        button("Show in wk", () => wk("task", w())),
        Spacer(),
        button("+ New", () => wk("new")),
      ]).paddingHorizontal(10).paddingVertical(2);
    case "section":
      return HStack([
        Text(() => entry().text).font(10).weight("semibold").color("tertiary"),
        Spacer(),
        Text("wk ↗").font(10).color("tertiary").cursor("pointer").onTap(() => wk("palette")),
      ]).paddingHorizontal(10).paddingTop(10);
    default:
      return HStack({ spacing: 8 }, [
        RoundedRectangle({ cornerRadius: 2 }).fill(() => w().color ?? "#7f7f7f33").frame({ width: 3, height: 28 }),
        VStack({ spacing: 1 }, [
          Text(() => w().title)
            .font(12).weight(() => (w().selected ? "semibold" : "regular"))
            .lineLimit(1).truncation("tail"),
          Text(() => w().description || w().branch || "")
            .font(10).color("tertiary").lineLimit(1).truncation("tail"),
        ]),
        Spacer(),
        Circle({ size: 6 }).fill(() => agentColor(w())),
      ])
        .paddingHorizontal(10).paddingVertical(4)
        .cornerRadius(7)
        .background(() => (w().selected ? "#7f7f7f24" : null))
        .hoverBackground("#7f7f7f1c")
        .frame({ maxWidth: "infinity" })
        .cursor("pointer")
        .onTap(() => cmux("workspace.select", { workspace_id: w().id }))
        .contextMenu([
          Button("Edit note in wk", () => wk("note", w())),
          Button("Show in wk", () => wk("task", w())),
        ]);
  }
}

sidebar(() =>
  VStack({ spacing: 6 }, [
    ForEach({ items: () => entries(), key: (e) => e.key }, (entry) => view(entry)),
    Spacer(),
  ]).paddingVertical(8)
);
