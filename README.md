# Need Academy

A single Spring Boot application that serves both the API and the web interface.
One build, one command, one URL. No Node, no separate frontend, no database to install.

## What you need on your Mac

- **Java 21**  → `java -version` should print 21 or higher
- **Maven**  → `mvn -v`

If either is missing:

```bash
brew install openjdk@21 maven
sudo ln -sfn /opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk \
  /Library/Java/JavaVirtualMachines/openjdk-21.jdk
```

## Run it

```bash
cd need-academy
mvn spring-boot:run
```

Then open **http://localhost:8080**

Two accounts are created the first time it starts:

| Role | Email | Password |
|---|---|---|
| Teacher | teacher@needacademy.com | teacher123 |
| Student | student@needacademy.com | student123 |

Change the teacher password in `src/main/java/com/needacademy/config/Seed.java`
before anyone else uses this.

## Build a single file you can deploy

```bash
mvn clean package
java -jar target/need-academy-1.0.0.jar
```

That JAR contains the API, the web interface, and the database driver.
Drop it on Railway, a VPS, or anywhere with Java 21.

## Where the data lives

A file-based H2 database at `./data/needacademy.mv.db`, created next to where you
run the app. It survives restarts. To wipe everything and start clean:

```bash
rm -rf data/
```

When you're ready for Postgres, replace the three `spring.datasource.*` lines in
`src/main/resources/application.properties`. Nothing else changes.

## How it works

**Teacher side**

- *Exercises*: build a reusable exercise: passages with a reading time, then
  questions with their own per-question time limits. Duplicate one to make a variant.
- *Students*: create accounts. You set the email and password and hand them over.
- *Assign*: pick an exercise, tick the students, set a deadline and how many attempts.
- *Results*: every attempt, question by question, with the time each answer took.

**Student side**

One exercise at a time. The passage appears for the number of seconds you set, then
disappears. Each question appears alone with its own countdown. No going back.

**The clock**

The countdown is drawn in the browser but decided on the server. Every step carries a
server-issued deadline; answers arriving after it (plus 3 seconds of network slack) are
recorded as timed out. Refreshing the page, closing the laptop, or changing the system
clock does not buy extra time.

## Level estimate

A CEFR level is only produced for a global assessment: the exercise must be a
PLACEMENT or a MOCK_EXAM *and* carry at least 12 graded questions
(`ExamService.MIN_QUESTIONS_FOR_LEVEL`). There, the percentage maps onto a band
relative to the exercise's target level: 90%+ on a B1 paper reads as B2, under
40% reads as A2.

Ordinary practice exercises get an encouragement message instead
(`ExamService.encouragement`). Skill breakdowns are still recorded for every
attempt, since that is what feeds the long-term profile, but the profile only
reads a level from breakdowns with at least four questions behind them.

The filter also applies on read (`ExamService.publishedLevel`), so attempts
submitted before this rule no longer show a level they should never have had.

## Database migrations

Every schema or data change is a numbered file under
`src/main/resources/db/migration`, applied once per database by Flyway and
recorded in `flyway_schema_history`. Nothing is typed by hand in the Neon
console. Naming rules and the two project-specific constraints (SQL must run on
both PostgreSQL and H2; a migration may not assume columns added by the entities
in the same release) are in `db/migration/CONVENTIONS.md`.

The existing production database is baselined at version 1 on first boot, so V1
is never executed there. New work starts at V2.

## Checking before delivery

Maven Central is unreachable from the execution sandbox, so the project can't be
compiled there. `tools/ScopeCheck.java` parses the source tree with javac's
parser (no dependencies needed) and reports syntax errors, duplicated methods,
out-of-scope or unknown names, calls to methods a project class doesn't declare,
and missing `java.util` / `java.time` imports. Needs a full JDK:

```bash
curl -sL -o jdk.tar.gz "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.5%2B11/OpenJDK21U-jdk_x64_linux_hotspot_21.0.5_11.tar.gz"
tar xzf jdk.tar.gz
./jdk-21.0.5+11/bin/javac -d tools/out tools/ScopeCheck.java
./jdk-21.0.5+11/bin/java -cp tools/out ScopeCheck src/main/java
node --check src/main/resources/static/app.js
```

## Project layout

```
src/main/java/com/needacademy/
  entity/     AppUser, Exercise, Section, Question, Assignment, Attempt, ItemResponse
  repo/       Spring Data repositories
  service/    ExamService: the timed engine and grading
  web/        AuthController, AdminController, StudentController
  config/     security, seed data
src/main/resources/
  static/     index.html (accueil public), css/ (une feuille par composant),
              partials/ (écrans HTML), js/ (modules ES) : voir css/README.md et js/README.md
  application.properties
```
