/** @type {import('next').NextConfig} */
const nextConfig = {
  output: "export",
  // Published at https://castlemilk.github.io/micropod/api/ — the repo's
  // gh-pages branch serves landing/ at /micropod/ and this app is copied
  // into landing/api/ by the pages workflow.
  basePath: "/micropod/api",
  trailingSlash: true,
  images: { unoptimized: true },
};

export default nextConfig;
