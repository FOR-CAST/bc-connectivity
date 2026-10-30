-- Quarto's {{< pagebreak >}} emits \newpage{} in LaTeX, which does not flush pending floats, so a
-- figure can drift past the page break. Rewrite it to \clearpage. Other formats are untouched.
function RawBlock(el)
  if el.format:match("^latex") or el.format == "tex" then
    if el.text:match("^%s*\\newpage{}%s*$") or el.text:match("^%s*\\newpage%s*$") then
      return pandoc.RawBlock(el.format, "\\clearpage")
    end
  end
end
