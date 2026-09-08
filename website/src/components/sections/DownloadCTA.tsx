import { Container } from "@/components/layout/Container";
import { Button } from "@/components/ui/Button";

export function DownloadCTA() {
  return (
    <section className="border-t border-border bg-bg-subtle py-20 sm:py-28">
      <Container className="text-center">
        <h2 className="text-3xl font-bold tracking-tight text-ink sm:text-4xl">
          Ready when you need it.
        </h2>
        <p className="mx-auto mt-4 max-w-xl text-lg leading-relaxed text-ink-soft">
          ResQNet is in active development. Get the current status and be
          first to know when it&apos;s available to install.
        </p>
        <div className="mt-8 flex justify-center">
          <Button href="/download/" size="lg">
            Get ResQNet
          </Button>
        </div>
      </Container>
    </section>
  );
}
