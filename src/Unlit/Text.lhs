> {-# LANGUAGE OverloadedStrings, CPP #-}
> module Unlit.Text (
>   unlit, relit
>   , Style, all, infer, latex, bird, jekyll,  haskell, markdown, tildefence, backtickfence
>   , Lang, forLang, WhitespaceMode(..)
> ) where

> import Data.Foldable (asum)
> import Data.Bool (bool)
> import Data.Maybe (fromMaybe, maybeToList)
> import Data.Monoid ((<>))
> import Prelude hiding (all, or, String, unlines, lines, drop)
> import Data.Text (Text, stripStart, stripEnd, isPrefixOf, isSuffixOf, isInfixOf, unlines, lines, unpack, drop)

What are literate programs?
===========================

There are several styles of literate programming. Most commonly,
these are LaTeX-style code tags, Bird tags and Markdown fenced code
blocks.

> data Delim
>   = LaTeX         BeginEnd
>   | OrgMode       BeginEnd (Maybe Lang)
>   | Bird
>   | Jekyll        BeginEnd (Maybe Lang)
>   | TildeFence    (Maybe Lang)
>   | BacktickFence (Maybe Lang)
>   deriving (Eq)

Some of these code blocks need to  carry around additional information.
For instance, LaTex code blocks use distinct opening and closing tags.

> data BeginEnd
>   = Begin
>   | End
>   deriving (Eq)

On the other hand, Markdown-style fenced code blocks can be annotated
with all sorts of information. Most prominently, their programming
language.

> type Lang = Text

In order to properly show these code blocks, we will define the
following instance.

> emitDelim :: Delim -> Text
> emitDelim (LaTeX Begin)     = "\\begin{code}"
> emitDelim (LaTeX End)       = "\\end{code}"
> emitDelim (OrgMode Begin l) = "#+BEGIN_SRC" >#< fromMaybe "" l
> emitDelim (OrgMode End _)   = "#+END_SRC"
> emitDelim  Bird             = ">"
> emitDelim (Jekyll Begin l)  = "{% highlight " >#< fromMaybe "" l >#< " %}"
> emitDelim (Jekyll End   _)  = "{% endhighlight %}"
> emitDelim (TildeFence l)    = "~~~" >#< fromMaybe "" l
> emitDelim (BacktickFence l) = "```" >#< fromMaybe "" l

Furthermore, we need a set of functions which is able to recognise
these code blocks.

> type Recogniser = Text -> Maybe Delim

For instance, in LaTeX-style, a codeblock is delimited by
`\begin{code}` and `\end{code}` tags, which must appear at the first
position (since we do not support indented code blocks).

> isLaTeX :: Recogniser
> isLaTeX l
>   | "\\begin{code}" `isPrefixOf` stripStart l = Just $ LaTeX Begin
>   | "\\end{code}"   `isPrefixOf` stripStart l = Just $ LaTeX End
>   | otherwise = Nothing

> isOrgMode :: Maybe Lang -> Recogniser
> isOrgMode lang l
>   | "#+BEGIN_SRC" `isPrefixOf` stripStart l
>     && maybe True (`isInfixOf` l) lang      = Just $ OrgMode Begin lang
>   | "#+END_SRC"   `isPrefixOf` stripStart l = Just $ OrgMode End Nothing
>   | otherwise = Nothing

In Bird-style, every line in a codeblock must start with a Bird tag.
A tagged line is defined as *either* a line containing solely the
symbol '>', or a line starting with the symbol '>' followed by at
least one space.

> isBird :: Recogniser
> isBird l = bool Nothing (Just Bird) (l == ">" || "> " `isPrefixOf` l)

Due to this definition, whenever we strip a bird tag, in normal
whitespace modes we also remove a the first space following it.

> stripBird :: Text -> Text
> stripBird = stripBird' KeepIndent

> stripBird' :: WhitespaceMode -> Text -> Text
> stripBird' KeepAll    l = " " <> drop 1 l
> stripBird' KeepIndent l = drop 2 l

Then we have Jekyll Liquid code blocks.

> isJekyll :: Maybe Lang -> Recogniser
> isJekyll lang l
>   | "{% highlight" `isPrefixOf` stripStart l
>     && maybe True (`isInfixOf` l) lang
>     && "%}" `isSuffixOf` stripEnd l     = Just $ Jekyll Begin lang
>   | "{% endhighlight %}" `isPrefixOf` l = Just $ Jekyll End   lang
>   | otherwise                           = Nothing

Lastly, Markdown supports two styles of fenced codeblocks: using
tildes or using backticks. These fenced codeblocks have as a
peculiarity that they can be defined to only match on fences for a
certain language.

Below we only check if the given language occurs *anywhere* in the
string; we don't bother parsing the entire line to see if it's
well-formed Markdown.

> isTildeFence :: Maybe Lang -> Recogniser
> isTildeFence lang l =
>   if "~~~" `isPrefixOf` stripStart l then
>     if maybe True (`isInfixOf` l) lang then
>       Just $ TildeFence lang
>     else
>       Just $ TildeFence Nothing
>   else
>     Nothing

> isBacktickFence :: Maybe Lang -> Recogniser
> isBacktickFence lang l =
>   if "```" `isPrefixOf` stripStart l then
>     if maybe True (`isInfixOf` l) lang then
>       Just $ TildeFence lang
>     else
>       Just $ TildeFence Nothing
>   else
>     Nothing

In general, we will also need a function that checks, for a given
line, whether it conforms to *any* of a set of given styles.

> isDelim :: Style -> Recogniser
> isDelim ds l = asum (map go ds)
>   where
>     go (LaTeX _)            = isLaTeX l
>     go  Bird                = isBird l
>     go (Jekyll _ lang)      = isJekyll lang l
>     go (TildeFence lang)    = isTildeFence lang l
>     go (BacktickFence lang) = isBacktickFence lang l
>     go (OrgMode _ lang)     = isOrgMode lang l

And, for the styles which use opening and closing brackets, we will
need a function that checks if these pairs match.

> match :: Delim -> Delim -> Bool
> match (LaTeX Begin)     (LaTeX End)             = True
> match (Jekyll Begin _)  (Jekyll End _)          = True
> match (OrgMode Begin _) (OrgMode End _)         = True
> match (TildeFence _)    (TildeFence Nothing)    = True
> match (BacktickFence _) (BacktickFence Nothing) = True
> match  _                 _                      = False

Note that Bird-tags are notably absent from the `match` function, as
they are a special case.

What do we want `unlit` to do?
==============================

The `unlit` program that we will implement below will do the following:
it will read a literate program from the standard input---allowing one
or more styles of code block---and emit only the code to the standard
output.

The options for source styles are as follows:

> type Style = [Delim]
>
> bird, latex, orgmode, haskell, jekyll, tildefence, backtickfence, markdown, all, infer :: Style
> bird             = [Bird]
> latex            = [LaTeX Begin, LaTeX End]
> orgmode          = [OrgMode Begin Nothing, OrgMode End Nothing]
> haskell          = latex <> bird
> jekyll           = [Jekyll Begin Nothing, Jekyll End Nothing]
> tildefence       = [TildeFence Nothing]
> backtickfence    = [BacktickFence Nothing]
> markdown         = bird <> tildefence <> backtickfence
> all              = latex <> markdown
> infer            = []

> forLang :: Lang -> Style -> Style
> forLang = map . setLang . Just

> setLang :: Maybe Lang -> Delim -> Delim
> setLang lang (TildeFence _)       = TildeFence lang
> setLang lang (BacktickFence _)    = BacktickFence lang
> setLang lang (OrgMode beginEnd _) = OrgMode beginEnd lang
> setLang lang (Jekyll beginEnd _)  = Jekyll beginEnd lang
> setLang _     d                   = d

Additionally, when the source style is empty, the program will
attempt to guess the style based on the first delimiter it
encounters. It will try to be permissive in this, and therefore, if
it encounters a Bird-tag, will infer general Markdown-style.

> doInfer :: Maybe Delim -> Style
> doInfer  Nothing             = []
> doInfer (Just (LaTeX _))     = latex
> doInfer (Just (Jekyll _ _))  = jekyll
> doInfer (Just (OrgMode _ _)) = orgmode
> doInfer (Just _)             = markdown

Lastly, we would like `unlit` to be able to operate in several
different whitespace modes. For now, these are:

> data WhitespaceMode
>   = KeepIndent -- ^ keeps only indentations
>   | KeepAll    -- ^ keeps all lines and whitespace

We would like to combine the inferred style with current styles as
one would combine maybe values using the alternative operator
`(<|>)`. Therefore, we will define our own version of this operator.

> or :: [a] -> [a] -> [a]
> xs `or` [] = xs
> [] `or` ys = ys
> xs `or` _  = xs

Thus, the `unlit` function will have two parameters: its source style
and the text to convert.

> unlit :: WhitespaceMode -> Style -> Text -> Text
> unlit ws ss = unlines . unlit' ws ss Nothing . zip [1..] . lines

However, the helper function `unlit'` is best thought of as a finite
state automaton, where the states are used to remember the what kind
of code block (if any) the automaton currently is in.

> type State = Maybe Delim

With this, the signature of `unlit'` becomes:

> unlit' :: WhitespaceMode -> Style -> State -> [(Int, Text)] -> [Text]
> unlit' _ _ _ [] = []
> unlit' ws ss q ((n, l):ls) = case (q, q') of
>
>
>   (Nothing  , Nothing)                 -> continue   $ lineIfKeepAll
>   (Nothing  , Just Bird)               -> open       $ lineIfKeepIndent <> [stripBird' ws l]
>   (Just Bird, Just Bird)               -> continue   $                     [stripBird' ws l]
>   (Just Bird, Nothing)                 -> close      $ lineIfKeepAll
>   (Nothing  , Just (LaTeX End))        -> spurious n $ LaTeX End
>   (Nothing  , Just (Jekyll End lang))  -> spurious n $ Jekyll End lang
>   (Nothing  , Just (OrgMode End lang)) -> spurious n $ OrgMode End lang
>   (Nothing  , Just _o)                 -> open       $ lineIfKeepAll <> lineIfKeepIndent
>   (Just _o  , Nothing)                 -> continue   $ [l]
>   (Just _o  , Just Bird)               -> continue   $ [l]
>   (Just o   , Just c)                  -> if not (o `match` c) then
>                                        spurious n c
>                                      else
>                                        close $ lineIfKeepAll
>   where
>     q'                = isDelim (ss `or` all) l
>     continueWith r l' = l' <> unlit' ws (ss `or` doInfer q') r ls
>     open              = continueWith q'
>     continue          = continueWith q
>     close             = continueWith Nothing
>     lineIfKeepAll     = case ws of KeepAll    -> [""]; _ -> []
>     lineIfKeepIndent  = case ws of KeepIndent -> [""]; _ -> []

What do we want `relit` to do?
==============================

Sadly, no, `relit` won't be able to take source code and
automatically convert it to literate code. I'm not quite up to the
challenge of automatically generating meaningful documentation from
arbitrary code... I wish I was.

What `relit` will do is read a literate file using one style of
delimiters and emit the same file using an other style of delimiters.

> relit :: Style -> Style -> Text -> Text
> relit ss ts = unlines . relit' ss (head ts) Nothing . zip [1..] . lines

Again, we will interpret the helper function `relit'` as an
automaton, which remembers the current state. However, we now also
need a function which can emit code blocks in a certain style. For
this purpose we will define a triple of functions.

TODO: Currently, if a delimiter is indented, running `relit` will remove this
      indentation. This is obviously an error, however changing it would require
      adding indentation information to all delimiters (which I'll do in the
      future, together with making a general `isEnd` predicate).

> emitBird :: Text -> Text
> emitBird l = "> " <> l
>
> emitOpen :: Delim -> Maybe Text -> [Text]
> emitOpen  Bird              l = "" : map emitBird (maybeToList l)
> emitOpen (LaTeX End)        l = emitOpen (LaTeX Begin) l
> emitOpen (Jekyll End lang)  l = emitOpen (Jekyll Begin lang) l
> emitOpen (OrgMode End lang) l = emitOpen (OrgMode Begin lang) l
> emitOpen  del               l = emitDelim del : maybeToList l
>
> emitCode :: Delim -> Text -> Text
> emitCode Bird l = emitBird l
> emitCode _    l = l
>
> emitClose :: Delim -> Text
> emitClose  Bird                = ""
> emitClose (LaTeX Begin)        = emitClose (LaTeX End)
> emitClose (Jekyll Begin lang)  = emitClose (Jekyll End lang)
> emitClose (OrgMode Begin lang) = emitClose (OrgMode End lang)
> emitClose  del                 = emitDelim (setLang Nothing del)

Using these simple functions we can easily define the `relit'`
function.

> relit' :: Style -> Delim -> State -> [(Int, Text)] -> [Text]
> relit' _ _   Nothing    [] = []
> relit' _ ts (Just Bird) [] = emitClose ts : []
> relit' _ _  (Just o)    [] = eof o
> relit' ss ts q ((n, l):ls) = case (q, q') of
>
>   (Nothing  , Nothing)                 -> l : continue
>   (Nothing  , Just Bird)               -> blockOpen     $ Just (stripBird l)
>   (Just Bird, Just Bird)               -> blockContinue $       stripBird l
>   (Just Bird, Nothing)                 -> blockClose
>   (Nothing  , Just (LaTeX End))        -> spurious n    $ LaTeX End
>   (Nothing  , Just (Jekyll End lang))  -> spurious n    $ Jekyll End lang
>   (Nothing  , Just (OrgMode End lang)) -> spurious n    $ OrgMode End lang
>   (Nothing  , Just _o)                 -> blockOpen     $ Nothing
>   (Just _o  , Nothing)                 -> blockContinue $ l
>   (Just _o  , Just Bird)               -> l : continue
>   (Just o   , Just c)                  -> if o `match` c then blockClose else spurious n c
>
>   where
>     q'               = isDelim (ss `or` all) l
>     continueWith  r  = relit' (ss `or` doInfer q') ts r ls
>     continue         = continueWith q
>     blockOpen     l' = emitOpen  ts l' <> continueWith q'
>     blockContinue l' = emitCode  ts l' : continue
>     blockClose       = emitClose ts   : continueWith Nothing

Helper functions
================

> infixr 5 >#<

> (>#<) :: Text -> Text -> Text
> "" >#< y  = y
> x  >#< "" = x
> x  >#< y  = x <> " " <> y

> eof :: Delim -> a
> eof q = error $ "unexpected EOF; unmatched " <> unpack (emitDelim q)

> spurious :: Int -> Delim -> a
> spurious n q = error $ "at line " <> show n <> ": spurious " <> unpack (emitDelim q)
