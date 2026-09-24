"use client";

import React, { useEffect } from "react";
import { ArrowRight } from "lucide-react";

/** Client-side redirect for retired doc paths — static export can't issue
 * server redirects, so old links land here and forward on. `href` is
 * relative to the page URL (e.g. "../../grpc/x/" from /rest/x/). */
export function Redirect({ href, label }: { href: string; label: string }) {
  useEffect(() => {
    window.location.replace(href);
  }, [href]);
  return (
    <div className="mx-auto max-w-xl px-6 py-24 text-center">
      <p className="text-muted">
        This page moved — redirecting to{" "}
        <a href={href} className="font-medium text-primary hover:underline">
          {label}
          <ArrowRight className="ml-1 inline h-3.5 w-3.5" />
        </a>
      </p>
    </div>
  );
}
