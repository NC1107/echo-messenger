#!/usr/bin/env python3
"""Selenium test for Echo messenger using Firefox."""

import os
import time
import json
import requests as http
from selenium import webdriver
from selenium.webdriver.firefox.options import Options
from selenium.webdriver.firefox.service import Service
from selenium.webdriver.common.by import By
from selenium.webdriver.common.keys import Keys
from selenium.webdriver.common.action_chains import ActionChains
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC
import geckodriver_autoinstaller

SERVER = os.environ.get("SERVER", "https://echo-messenger.us")
APP = os.environ.get("APP", "https://echo-messenger.us")
SS = "tests/selenium/screenshots"
os.makedirs(SS, exist_ok=True)

geckodriver_autoinstaller.install()

def api(method, path, data=None, token=None):
    headers = {"Content-Type": "application/json", "User-Agent": "EchoTest/1.0"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    r = getattr(http, method.lower())(f"{SERVER}{path}", json=data, headers=headers, timeout=10)
    return r.json()

def ss(d, name):
    d.save_screenshot(f"{SS}/{name}.png")

def make_driver():
    opts = Options()
    opts.add_argument("--width=1280")
    opts.add_argument("--height=720")
    return webdriver.Firefox(options=opts)

def wait(d, s=3):
    time.sleep(s)

def enable_accessibility(d):
    """Click Flutter's hidden 'Enable accessibility' button."""
    try:
        btn = d.find_element(By.XPATH, "//*[@role='button' and contains(@aria-label, 'accessibility')]")
        d.execute_script("arguments[0].click();", btn)
        wait(d, 2)
        print("  Accessibility enabled")
    except:
        # Try clicking at (-1,-1) where it's positioned
        d.execute_script("""
            var btn = document.querySelector('[role="button"]');
            if (btn) btn.click();
        """)
        wait(d, 2)
        print("  Accessibility enabled (js fallback)")

def login(d, username, password):
    d.get(APP)
    wait(d, 6)

    # Flutter web: click the username field area on the canvas, then type
    # The input fields are rendered by Flutter at approximately center of the page
    size = d.get_window_size()
    cx, cy = size['width'] // 2, size['height'] // 2

    # Use JavaScript to click at absolute coordinates (Selenium ActionChains uses relative offsets)
    def click_at(x, y):
        d.execute_script(f"document.elementFromPoint({x},{y})?.click() || document.dispatchEvent(new MouseEvent('click', {{clientX:{x}, clientY:{y}, bubbles:true}}));")

    click_at(cx, cy - 40)  # Username field
    wait(d, 0.5)

    # Type username
    ActionChains(d).send_keys(username).perform()
    wait(d, 0.3)

    # Tab to password
    ActionChains(d).send_keys(Keys.TAB).perform()
    wait(d, 0.3)

    # Type password
    ActionChains(d).send_keys(password).perform()
    wait(d, 0.3)

    # Submit
    ActionChains(d).send_keys(Keys.RETURN).perform()
    wait(d, 8)

    # Dismiss popups
    for _ in range(3):
        ActionChains(d).send_keys(Keys.ESCAPE).perform()
        wait(d, 0.3)

    # Enable accessibility AFTER login
    enable_accessibility(d)
    wait(d, 2)

def dump_elements(d, label=""):
    """Print all interactive elements for debugging."""
    print(f"\n--- Elements {label} ---")
    for tag in ["input", "button", "a", "[role='button']", "[role='textbox']", "flt-semantics"]:
        try:
            els = d.find_elements(By.CSS_SELECTOR, tag) if not tag.startswith("[") else d.find_elements(By.XPATH, f"//*{tag}")
            if els:
                print(f"  {tag}: {len(els)} found")
                for i, el in enumerate(els[:5]):
                    loc = el.location
                    label_attr = el.get_attribute("aria-label") or el.text or ""
                    role = el.get_attribute("role") or ""
                    print(f"    [{i}] ({loc['x']},{loc['y']}) role={role} label='{label_attr[:50]}'")
        except:
            pass

def main():
    ts = str(int(time.time()))[-4:]
    u1, u2, pw = f"fx{ts}a", f"fx{ts}b", "testpass1"
    print(f"\n=== SELENIUM FIREFOX TEST ===\nUsers: {u1}, {u2}\n")

    # API setup
    health = api("GET", "/api/health")
    print(f"✅ Health: v{health.get('version')}")

    r1 = api("POST", "/api/auth/register", {"username": u1, "password": pw})
    r2 = api("POST", "/api/auth/register", {"username": u2, "password": pw})
    print(f"✅ Registered: {u1}, {u2}")

    c = api("POST", "/api/contacts/request", {"username": u2}, r1["access_token"])
    api("POST", "/api/contacts/accept", {"contact_id": c["contact_id"]}, r2["access_token"])
    print("✅ Contacts established")

    d1 = make_driver()
    d2 = make_driver()

    try:
        # Login
        print("\n--- Login ---")
        login(d1, u1, pw)
        ss(d1, "01-u1-home")
        print(f"✅ {u1} logged in")

        login(d2, u2, pw)
        ss(d2, "02-u2-home")
        print(f"✅ {u2} logged in")

        # Dump elements to understand the DOM
        dump_elements(d1, "after login")

        # Wait for conversations
        print("\n--- Waiting for conversations (20s) ---")
        wait(d1, 20)
        ss(d1, "03-u1-after-wait")
        dump_elements(d1, "after wait")

        # Try clicking the compose button
        print("\n--- Compose menu ---")
        # Find all clickable role=button elements
        buttons = d1.find_elements(By.XPATH, "//*[@role='button']")
        print(f"  Found {len(buttons)} buttons")
        for i, btn in enumerate(buttons):
            try:
                loc = btn.location
                label = btn.get_attribute("aria-label") or ""
                print(f"    [{i}] ({loc['x']},{loc['y']}) '{label}'")
            except:
                pass

        # Find textboxes (for message input)
        textboxes = d1.find_elements(By.XPATH, "//*[@role='textbox']")
        print(f"  Found {len(textboxes)} textboxes")
        for i, tb in enumerate(textboxes):
            try:
                loc = tb.location
                label = tb.get_attribute("aria-label") or ""
                print(f"    [{i}] ({loc['x']},{loc['y']}) '{label}'")
            except:
                pass

        ss(d1, "04-element-map")

        # Try to find and click conversation items
        list_items = d1.find_elements(By.XPATH, "//*[@role='listitem' or @role='option']")
        print(f"  Found {len(list_items)} list items")

        # Try generic approach: find all elements and their text
        all_els = d1.find_elements(By.XPATH, "//*[string-length(normalize-space(text())) > 0 and string-length(normalize-space(text())) < 50]")
        print(f"\n--- All text elements ---")
        for el in all_els[:30]:
            try:
                txt = el.text.strip()
                if txt:
                    tag = el.tag_name
                    loc = el.location
                    print(f"    <{tag}> at ({loc['x']},{loc['y']}): '{txt}'")
            except:
                pass

        # Screenshot final state
        ss(d1, "05-final-u1")
        ss(d2, "06-final-u2")

        print("\n=== DONE ===")

    finally:
        d1.quit()
        d2.quit()

if __name__ == "__main__":
    main()
