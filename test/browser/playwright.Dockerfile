# The pinned browser runtime for the CI browser matrix. CI runs the tests inside this exact image and never
# builds this file; it exists so Dependabot can update the image together with @playwright/test.
FROM mcr.microsoft.com/playwright:v1.64.1-noble@sha256:47b510dd9230bf0b9bfc9b20102241e577ea7a99334ab4c3ca19f19770e9b8ea
