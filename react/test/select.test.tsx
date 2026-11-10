import { fireEvent, render } from "@testing-library/react";
import { Select } from "../src/components/Select";

// the menu is portalled out of the themed tree and carries .ak-root (which resets every token to
// the engine default), so it must take the theme the trigger RESOLVES. jsdom does not cascade custom properties into
// getComputedStyle, so the trigger's resolved style is stubbed — what a browser returns for a button under the board
// root's inline theme (or a host :root rule).
describe("Select menu theme", () => {
  afterEach(() => vi.restoreAllMocks());

  it("copies the trigger's resolved --ak-* tokens onto the portalled menu", () => {
    const real = window.getComputedStyle.bind(window);
    const resolved = { "--ak-ink": "rgb(1, 2, 3)", "--ak-panel": " rgb(4, 5, 6)", color: "rgb(9, 9, 9)" } as Record<
      string,
      string
    >;
    vi.spyOn(window, "getComputedStyle").mockImplementation((el, pseudo) =>
      el instanceof HTMLButtonElement
        ? ({ getPropertyValue: (n: string) => resolved[n] ?? "" } as unknown as CSSStyleDeclaration)
        : real(el, pseudo),
    );
    const { getByRole } = render(
      <Select
        ariaLabel="Transition"
        options={[
          { value: "a", label: "A" },
          { value: "b", label: "B" },
        ]}
        value="a"
        onChange={() => {}}
      />,
    );
    fireEvent.click(getByRole("button"));
    const menu = document.querySelector<HTMLElement>('ul.menu[role="listbox"]')!;
    expect(menu).toHaveClass("ak-root");
    expect(menu.style.getPropertyValue("--ak-ink")).toBe("rgb(1, 2, 3)");
    expect(menu.style.getPropertyValue("--ak-panel")).toBe("rgb(4, 5, 6)");
    expect(menu.style.getPropertyValue("color")).toBe("");
  });
});
