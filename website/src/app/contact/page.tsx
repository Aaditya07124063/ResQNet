import { Suspense } from "react";
import { Container } from "@/components/layout/Container";
import { PageHero } from "@/components/sections/PageHero";
import { ContactForm } from "@/components/forms/ContactForm";
import { pageMetadata } from "@/lib/seo";

export const metadata = pageMetadata({
  title: "Contact",
  description:
    "Get in touch with ResQNet for general questions, partnerships, organizational deployment, government/institutional inquiries, or technical questions.",
  path: "/contact/",
});

export default function ContactPage() {
  return (
    <>
      <PageHero
        eyebrow="Contact"
        title="Talk to ResQNet."
        description="Whether you're a first-time visitor, a potential partner, or an organization exploring a deployment — this reaches the same place."
      />

      <section className="py-20 sm:py-28">
        <Container className="mx-auto max-w-xl">
          <Suspense fallback={null}>
            <ContactForm />
          </Suspense>
        </Container>
      </section>
    </>
  );
}
