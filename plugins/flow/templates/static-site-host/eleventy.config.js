// Eleventy reads the pages in src/ and writes the built site to _site/.
// CI and the deploy step use _site/, so keep the output folder name.
export default function () {
  return {
    dir: {
      input: "src",
      output: "_site",
    },
  };
}
