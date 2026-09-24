import React from "react";
import type { Metadata } from "next";
import { Redirect } from "@/components/redirect";

export const metadata: Metadata = {
  title: "Moved",
  robots: { index: false },
};

export default function RestIndexRedirect() {
  return <Redirect href="../grpc/" label="API reference" />;
}
