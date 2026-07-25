# Product

## Status

Public pre-1.0 preview. The canonical product and repository name is **Moonglade**.

## Users

Developers running opencode, Claude Code, or Codex CLI in several macOS terminal tabs or tmux panes. They need to notice blocked agents and return to the exact session without leaving their current workflow to inspect a dashboard.

## Product Purpose

Moonglade is a passive, notch-adjacent status indicator. Success means users can see active-session counts at a glance, notice requests for attention within five seconds, and reach the exact terminal session with one click.

## Brand Personality

Quiet, precise, and native. The interface should feel like a small piece of macOS system instrumentation rather than another agent-management product.

## Anti-references

- Command centers, token dashboards, agent controls, and dense monitoring consoles.
- Aggressive alerts, saturated inactive states, decorative animation, or oversized chrome.
- Generic floating cards that compete with the user's terminal instead of disappearing beside the notch.

## Design Principles

- Show only information that changes the user's next action.
- Make attention noticeable without making it alarming.
- Preserve terminal context so every session remains individually actionable.
- Prefer familiar macOS behavior and materials over branded novelty.
- Degrade gracefully when terminal automation permission is unavailable.

## Accessibility & Inclusion

Use native buttons and popovers with descriptive accessibility labels, keyboard access, and visible focus. Never communicate status by color alone. Respect Reduce Motion by replacing the attention pulse with a steady indicator.
