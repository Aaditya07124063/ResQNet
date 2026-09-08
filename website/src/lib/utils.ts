import { clsx, type ClassValue } from "clsx";

/** Thin wrapper around clsx — kept as its own module so a future switch
 * to a class-merging strategy only touches one file. */
export function cn(...inputs: ClassValue[]): string {
  return clsx(inputs);
}
