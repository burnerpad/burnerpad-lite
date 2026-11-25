# The pinned browser runtime for the CI browser matrix. CI runs the tests inside this exact image and never
# builds this file; it exists so Dependabot can update the image together with @playwright/test.
FROM mcr.microsoft.com/playwright:v1.65.1-noble@sha256:1507cbfc550a63a6b7396791ca4f00df17beb56342d2447b3f106c306f525579
