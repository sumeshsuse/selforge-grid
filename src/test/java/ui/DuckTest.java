package ui;

import org.openqa.selenium.By;
import org.openqa.selenium.Dimension;
import org.openqa.selenium.Keys;
import org.openqa.selenium.WebDriver;
import org.openqa.selenium.WebElement;
import org.openqa.selenium.chrome.ChromeOptions;
import org.openqa.selenium.edge.EdgeOptions;
import org.openqa.selenium.firefox.FirefoxOptions;
import org.openqa.selenium.remote.RemoteWebDriver;
import org.testng.Assert;
import org.testng.annotations.*;

import java.net.URI;
import java.net.URL;
import java.time.Duration;

public class DuckTest {

    private WebDriver driver;

    @Parameters({"browser", "gridUrl"})
    @BeforeClass(alwaysRun = true)
    public void setUp(@Optional("chrome") String browser,
                      @Optional String gridUrlFromXml) throws Exception {
        String gridUrl = pick(
                gridUrlFromXml,
                System.getProperty("grid.url"),
                System.getProperty("GRID_URL"),
                System.getenv("GRID_URL")
        );

        if (gridUrl == null || gridUrl.isBlank()) {
            throw new IllegalStateException(
                    "GRID URL is missing. Pass -Dgrid.url=http://host:4444 or TestNG param 'gridUrl'.");
        }

        URL remote = URI.create(gridUrl.trim()).toURL();
        driver = new RemoteWebDriver(remote, optionsFor(browser));
        driver.manage().timeouts().implicitlyWait(Duration.ofSeconds(3));
        driver.manage().window().setSize(new Dimension(1280, 900));
    }

    @Test
    public void duckSearch() {
        driver.get("https://duckduckgo.com/");
        WebElement box = driver.findElement(By.name("q"));
        box.sendKeys("Selenium Grid");
        box.sendKeys(Keys.ENTER);

        // quick-n-simple wait loop (kept tiny on purpose)
        long end = System.nanoTime() + Duration.ofSeconds(10).toNanos();
        while (System.nanoTime() < end) {
            if (driver.getTitle().toLowerCase().contains("selenium")) break;
            sleep(200);
        }
        Assert.assertTrue(driver.getTitle().toLowerCase().contains("selenium"),
                "Title should contain 'selenium'");
    }

    @Test(dependsOnMethods = "duckSearch")
    public void exampleDotComHasHeading() {
        driver.get("https://example.com/");
        String h1 = driver.findElement(By.tagName("h1")).getText();
        Assert.assertTrue(h1.toLowerCase().contains("example"),
                "H1 should contain 'Example'");
    }

    @AfterClass(alwaysRun = true)
    public void tearDown() {
        if (driver != null) driver.quit();
    }

    // ---------- helpers ----------
    private static org.openqa.selenium.Capabilities optionsFor(String name) {
        String b = (name == null ? "chrome" : name).trim().toLowerCase();
        switch (b) {
            case "chrome":  return new ChromeOptions().setAcceptInsecureCerts(true);
            case "firefox": return new FirefoxOptions().setAcceptInsecureCerts(true);
            case "edge":    return new EdgeOptions().setAcceptInsecureCerts(true);
            default: throw new IllegalArgumentException("Unsupported browser: " + name);
        }
    }

    private static String pick(String... vals) {
        for (String v : vals) if (v != null && !v.trim().isEmpty()) return v;
        return null;
    }

    private static void sleep(long ms) {
        try { Thread.sleep(ms); } catch (InterruptedException ignored) {}
    }
}
