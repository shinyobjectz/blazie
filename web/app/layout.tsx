import type { Metadata, Viewport } from "next";
import { Geist, Geist_Mono, Pixelify_Sans } from "next/font/google";
import "./globals.css";

/**
 * Three faces, three jobs. The rule is that pixel is a *mark*, not a heading
 * face — it was doing all three and the page read as a poster.
 *
 *   pixel  the wordmark, and the four operation names. nothing else.
 *   sans   headings and prose. the thing people actually read.
 *   mono   facts, names, code, anything a caller would paste.
 */
const pixel = Pixelify_Sans({
  variable: "--font-pixel",
  subsets: ["latin"],
  weight: ["400", "500", "600", "700"],
});

const sans = Geist({
  variable: "--font-sans",
  subsets: ["latin"],
});

const mono = Geist_Mono({
  variable: "--font-mono",
  subsets: ["latin"],
});

export const metadata: Metadata = {
  title: "blazie",
  description:
    "The backend agents run on. Durable memory that records where every fact came from, a graph you did not have to model, and sandboxes to run agent code in.",
  metadataBase: new URL("https://blazie.dev"),
  openGraph: {
    title: "blazie",
    description: "The backend agents run on.",
    url: "https://blazie.dev",
    siteName: "blazie",
    images: ["/brand/blazie-mark.png"],
  },
};

/**
 * blazie is dark-only, and saying so is what stops a browser painting light
 * form controls and scrollbars into it. It also tells extensions that invert
 * pages that there is nothing here to invert — Dark Reader rewrites every fill
 * and stroke before React hydrates, which surfaces as a hydration mismatch on a
 * page that is in fact fine.
 */
export const viewport: Viewport = {
  colorScheme: "dark",
  themeColor: "#000000",
};

export default function RootLayout({ children }: LayoutProps<"/">) {
  return (
    <html
      lang="en"
      className={`${pixel.variable} ${sans.variable} ${mono.variable} h-full antialiased`}
    >
      <body className="min-h-full flex flex-col bg-black text-white">
        {children}
      </body>
    </html>
  );
}
