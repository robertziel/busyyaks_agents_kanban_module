// A person's picture (an identity that is an email address): the host config's `avatar_url` template with {sha256} =
// the hex SHA-256 of the trimmed, lower-cased address (Gravatar's scheme). Computed once per address; an address whose
// image failed to load (the service has no picture on record: d=404) is remembered, so the initials show without
// asking again. null template = no request leaves the page.
import { useEffect, useState } from "react";

const urls = new Map<string, Promise<string>>();
const missing = new Set<string>();

export async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export function avatarUrl(template: string, email: string): Promise<string> {
  const key = `${template}\n${email.trim().toLowerCase()}`;
  let url = urls.get(key);
  if (!url) {
    url = sha256Hex(email.trim().toLowerCase()).then((h) => template.replace("{sha256}", h));
    urls.set(key, url);
  }
  return url;
}

// the picture's URL once known; null = none (no template, not an email address, or no picture on record)
export function usePersonAvatar(template: string | null | undefined, email: string): [string | null, () => void] {
  const [src, setSrc] = useState<string | null>(null);
  const usable = !!template && email.includes("@");
  useEffect(() => {
    if (!usable || !template) {
      setSrc(null);
      return;
    }
    let live = true;
    void avatarUrl(template, email).then((u) => live && setSrc(missing.has(u) ? null : u));
    return () => {
      live = false;
    };
  }, [usable, template, email]);
  const failed = () => {
    if (src) missing.add(src);
    setSrc(null);
  };
  return [src, failed];
}

// tests only: forget what was computed and what failed
export function resetAvatars() {
  urls.clear();
  missing.clear();
}
