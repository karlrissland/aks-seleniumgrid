import pytest
import time
from selenium.webdriver.common.by import By
from selenium.webdriver.common.keys import Keys
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC

class TestBingSearch:
    """Test suite for validating UI navigation and search on Bing.com across browsers."""

    def test_bing_homepage_loads(self, driver):
        """Verify that Bing homepage loads successfully and contains the search input."""
        driver.get("https://www.bing.com")
        
        # Check page title
        assert "Bing" in driver.title or "Microsoft Bing" in driver.title, f"Unexpected title: {driver.title}"
        
        # Verify search box is present and visible
        wait = WebDriverWait(driver, 15)
        search_box = wait.until(
            EC.presence_of_element_located((By.NAME, "q"))
        )
        assert search_box.is_displayed(), "Bing search box should be visible on the home page."

    def test_bing_search_query_execution(self, driver):
        """Execute a search query on Bing and verify that search results are displayed."""
        driver.get("https://www.bing.com")
        
        wait = WebDriverWait(driver, 15)
        search_box = wait.until(
            EC.element_to_be_clickable((By.NAME, "q"))
        )
        
        query = "Azure Kubernetes Service Selenium Grid"
        search_box.clear()
        search_box.send_keys(query)
        search_box.send_keys(Keys.RETURN)
        
        # Wait for search results container or result items
        results_container = wait.until(
            EC.presence_of_element_located((By.ID, "b_results"))
        )
        assert results_container.is_displayed(), "Bing results container ('#b_results') should be displayed."
        
        # Verify result headers are present
        result_headers = driver.find_elements(By.CSS_SELECTOR, "#b_results li.b_algo h2")
        assert len(result_headers) > 0, "Expected at least one search result item."
        
        first_title = result_headers[0].text
        print(f"\n[Bing] First result title ({driver.name}): {first_title}")
        assert len(first_title) > 0, "First search result title should not be empty."
