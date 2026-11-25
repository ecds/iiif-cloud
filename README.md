# FairImage

## Setup

1. Run `bundle install` to install the Rails dependencies.
2. `cd` into `client` and run `yarn` to install the client dependencies.
3. Additionally, FairImage requires the following packages to be installed on your server or dev machine if you plan to run the test suite or to use the features in parentheses:
   - `ffmpeg` (video uploads)
   - `imagemagick` (image and PDF uploads)
   - `ghostscript` (PDF uploads)

To start FairImage, run `bundle exec rake start`.

## Transcripts

FairImage can transcribe uploaded audio and video. Transcription is off until `TRANSCRIPTION_SERVICE` is set; see `.env.example` for the settings.

When it's on, each new or replaced audio or video file is sent to the service. The transcript is stored with the resource's files and added to its manifest as a WebVTT `supplementing` annotation on the canvas, which IIIF viewers can show as captions. It is served at `/public/resources/:uuid/transcript.vtt`, and the service's full output, including word timings, at `transcript.json`.

The only service so far is `aws_transcribe`, which uses Amazon Transcribe and needs content stored in S3. The credentials it runs with need `transcribe:StartTranscriptionJob`, `transcribe:GetTranscriptionJob` and `transcribe:DeleteTranscriptionJob`, and read access to the bucket. Transcribe accepts MP3, MP4, M4A, WAV, FLAC, Ogg, WebM and AMR files; others, such as QuickTime `.mov`, fail with the reason recorded on the resource.

To transcribe existing recordings, run `bundle exec rake transcripts:create`. Set `PROJECT_ID` to limit it to one project.

## Local Development with Clerk

To run FairImage locally, you'll need to set up Clerk. Follow these steps:

1. Create a Clerk account at [https://clerk.com](https://clerk.com).
2. Create a new application in Clerk.
3. Make sure organizations are enabled 
4. Obtain your Clerk API keys under Instance -> Configure -> API Keys.
5. Plug them into your `.env` file as `VITE_CLERK_PUBLISHABLE_KEY` and `CLERK_SECRET_KEY`.
6. Obtain your Clerk sign in URL under Configure -> Developers -> Paths -> Component paths -> `<SignIn />`
7. Plug it into your `.env` file as `VITE_CLERK_SIGN_IN_URL`.

You won't be able to sign in until the `sso_id` value is set on the FairImage user record you want to use.

Assuming you've got your FairImage database set up with users and orgs (either by `heroku pg:pull`ing from staging or creating some records yourself in the console), take these steps:

For each user you want to work with (you'll probably want one admin and one non-admin):
1. Create a corresponding account in the Users tab in Clerk.
2. Copy the User ID value from Clerk and plug it into the FairImage user's `sso_id` field.
3. If you want the account to be an admin, include `is_global_admin: true` in the private metadata.

For each organization:
1. Create a corresponding organization in the Organizations tab in Clerk.
2. Copy the Organization ID value from Clerk and plug it into the FairImage organization's `sso_id` field.
3. Add whichever users you want under the Members tab on the organization's Clerk page. (Note: roles are irrelevant to FairImage, but you may want to set them to reasonable values if you're planning to use this Clerk org for other apps.)
