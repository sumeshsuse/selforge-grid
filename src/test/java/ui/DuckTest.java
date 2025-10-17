package ui;

import org.openqa.selenium.WebDriver;
import org.openqa.selenium.chrome.ChromeOptions;
import org.openqa.selenium.remote.RemoteWebDriver;
import org.testng.Assert;
import org.testng.annotations.AfterMethod;
import org.testng.annotations.BeforeMethod;
import org.testng.annotations.Test;

import java.net.URL;

public class DuckTest {
    private WebDriver driver;

    @BeforeMethod
    public void setUp() throws Exception {
        String grid = System.getProperty("gridUrl", "http://localhost:4444"); // pass -DgridUrl=...
        driver = new RemoteWebDriver(new URL(grid), new ChromeOptions());
    }

    @Test
    public void canOpenDuckDuckGo() {
        driver.get("https://duckduckgo.com/");
        Assert.assertTrue(driver.getTitle().toLowerCase().contains("duck"),
                "Page title should contain 'duck'");
    }

    @AfterMethod(alwaysRun = true)
    public void tearDown() {
        if (driver != null) driver.quit();
    }
}
