---
name: meal
description: Route the user's meal-platform request (SimplyCarbs employee ordering) to the right sub-agent. Use when the user types "/meal" or says anything about checking, browsing, ordering, 便當, or cancelling便當／午餐／晚餐 on the employee meal platform. Examples: "/meal 看今天訂了什麼", "/meal 4/30 午餐有什麼", "/meal 訂 3 號", "/meal 取消 4/29". Delegates to meal-checker (read) or meal-order (list / order / cancel).
---

# Meal

Thin router skill for the Amazon employee meal platform. This skill does not call the platform itself — it picks the right sub-agent and briefs it.

## Two sub-agents

| Agent | What it does | Writes? |
|---|---|---|
| `meal-checker` | Read existing confirmed lunch/dinner orders | No |
| `meal-order` | List available menus, place orders, cancel orders | Yes |

## Routing rules

Match the user's intent to one agent and delegate via the `Agent` tool. **Never do platform interactions yourself** (no playwright MCP, no direct node invocations) — let the sub-agent handle it so the flow, prompts, and headless-only guarantees stay consistent.

### Use `meal-checker` when the user is asking about **existing** orders

Keywords: "訂了什麼", "今天訂餐了嗎", "查訂餐", "我的訂單", "check my lunch/dinner", "有沒有訂", "list my orders".

### Use `meal-order` when the user wants to **browse menus, order, or cancel**

Keywords: "有什麼便當", "菜單", "可以訂什麼", "幫我訂", "訂 N 號", "下訂", "取消 <date>", "cancel my order".

### Ambiguity → ask first

- If the request doesn't specify **lunch vs dinner** and the action is "list menu" / "order" / "cancel", ask the user which meal period before delegating. The platform uses separate URLs for lunch and dinner, so guessing is wasteful.
- If the request could be either "show me what I ordered" or "show me the menu", ask which.

## Delegating

When you invoke the sub-agent, pass along:

1. The user's original request (so tone / specifics aren't lost)
2. Any date/meal-period the user specified or that you confirmed
3. Any confirmation state — e.g. "user confirmed they want to order item #3" so the agent knows it can proceed to the real submit

Example dispatch prompt for meal-order:

```
User wants to see the lunch menu for 2026-04-30. Run list-menu.js LUNCH 2026-04-30,
show the numbered list to the user, then wait for them to pick.
```

## Constraints inherited from the sub-agents

- **Headless only.** meal-order scripts run Playwright headless; never open the visible playwright MCP browser for meal-platform work.
- **Confirm before writes.** Placing or cancelling an order requires explicit user confirmation (date + meal period + item). A single prior approval does not carry over.
- **Verify after writes.** After order.js or cancel.js succeeds, the sub-agent reruns meal-checker to confirm the change actually landed. Don't short-circuit this.
- **Numbered menu listings.** When the user sees a menu, items are numbered continuously across shops (shop A: 1-5, shop B: 6-10, etc.) so they can pick by number.
