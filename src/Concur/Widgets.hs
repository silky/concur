{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections     #-}
module Concur.Widgets where

import           Concur.Notify                 (Notify (..), newNotify)
import           Concur.Run                    (HTML, HTMLNodeName)
import           Concur.Types                  (Widget, display, effect,
                                                wrapView)

import           Control.Applicative           (Alternative, empty, (<|>))
import           Control.Concurrent            (forkIO, threadDelay)
import           Control.Concurrent.STM        (STM, atomically)
import           Control.Monad.IO.Class        (MonadIO (..))
import           Control.Monad.State           (execStateT, get, lift, put, when)
import           Control.MonadSTM              (MonadSTM (liftSTM))

import           Data.List                     (intercalate)
import           Data.Maybe                    (mapMaybe)
import           Data.String                   (fromString)
import           Data.Void                     (Void, absurd)

import qualified Data.JSString                 as JSS
import           GHCJS.DOM                     (currentDocumentUnchecked)
import           GHCJS.DOM.EventM              (mouseClientXY, on)
import           GHCJS.DOM.GlobalEventHandlers (click)
import           GHCJS.DOM.Types               (JSM)
import qualified GHCJS.VDOM.Attribute          as A
import qualified GHCJS.VDOM.Element            as E
import qualified GHCJS.VDOM.Event              as Ev

import           Data.MonadTransMap            (MonadTransMap, liftMap)

-- Global mouse click notifications
documentClickNotifications :: JSM (Notify (Int,Int))
documentClickNotifications = do
  n <- liftIO $ atomically newNotify
  doc <- currentDocumentUnchecked
  _ <- on doc click $ do
    (x, y) <- mouseClientXY
    liftIO $ atomically $ notify n (x,y)
  return n

-- Returns a widget which waits for a Notification to happen
listenNotify :: Monoid v => Notify a -> Widget v a
listenNotify = effect mempty . fetch

-- Text display widget
text :: String -> Widget HTML a
text s = display [E.text $ JSS.pack s]

-- General IO Effects
io :: Monoid v => IO a -> JSM (Widget v a)
io m = liftIO $ do
  n <- atomically newNotify
  _ <- forkIO $ m >>= atomically . notify n
  return $ effect mempty $ fetch n

-- Delay widget
delay :: Monoid v => Int -> JSM (Widget v ())
delay i = io $ threadDelay (i*1000000)

-- A clickable button widget
button :: String -> Widget HTML ()
button s = clickEl E.button [] [text s]

-- An Element which can be clicked. This requires that the children never return.
clickEl :: HTMLNodeName [A.Attribute] -> [A.Attribute] -> [Widget HTML Void] -> Widget HTML ()
clickEl e attrs children = either (const ()) absurd <$> elEvent Ev.click e attrs (orr children)

-- Handle arbitrary events on an element.
-- Returns Right on child events, and Left on event
elEvent :: ((a -> IO ()) -> A.Attribute)
        -> HTMLNodeName [A.Attribute]
        -> [A.Attribute]
        -> Widget HTML b
        -> Widget HTML (Either a b)
elEvent evt e attrs w = do
  n <- liftSTM newNotify
  let wEvt = effect mempty $ fetch n
  let child = el_ e (evt (atomically . notify n): attrs) w
  fmap Left wEvt <|> fmap Right child

-- A text label which can be edited by double clicking.
editableText :: String -> Widget HTML String
editableText s = elEvent Ev.dblclick E.span [] (text s) >> inputEnter s

-- Text input. Returns the contents on keypress enter.
inputEnter :: String -> Widget HTML String
inputEnter def = do
  n <- liftSTM newNotify
  let handleKeypress e = atomically $ when (Ev.key e == "Enter") $ notify n $ JSS.unpack $ Ev.inputValue e
  let txt = E.input (A.value $ JSS.pack def, Ev.keydown handleKeypress) ()
  effect [txt] $ fetch n

-- Text input. Returns the contents on every change.
-- This allows setting the value of the textbox, however
--  it suffers from the usual virtual-dom lost focus problem :(
input :: String -> Widget HTML String
input def = do
  n <- liftSTM newNotify
  let txt = E.input (A.value $ JSS.pack def, Ev.input (atomically . notify n . JSS.unpack . Ev.inputValue)) ()
  effect [txt] $ fetch n

-- Text input. Returns the contents on keypress enter.
-- This one does not allow setting the value of the textbox, however
--  this does not suffer from the virtual-dom lost focus problem, as
--  the vdom representation of the textbox never changes
mkInput :: STM (Widget HTML String)
mkInput = do
  n <- newNotify
  let txt = E.input (Ev.input (atomically . notify n . JSS.unpack . Ev.inputValue)) ()
  return $ effect [txt] $ fetch n

-- A custom widget. An input field with a button.
-- When the button is pressed, the value of the input field is returned.
-- Note the use of local state to store the input value
inputWithButton :: String -> String -> Widget HTML String
inputWithButton label def = do
  inp <- liftSTM mkInput
  flip execStateT def $ go inp
  where
    -- On text change, we simply update the state, but on button press, we return the current state
    go inp= w inp >>= either (\s -> put s >> go inp) (const get)
    -- Note we put a space between the text and the button. `text` widget is polymorphic and can be inserted anywhere
    w inp = fmap Left (lift inp) <|> lift (text " ") <|> fmap Right (lift $ button label)

-- A Checkbox
checkbox :: Bool -> Widget HTML Bool
checkbox checked = do
  n <- liftSTM newNotify
  let chk = E.input (Ev.click (const $ atomically $ notify n (not checked))) ()
  effect [chk] $ fetch n

-- Append multiple widgets together
-- TODO: Make this more efficient
orr :: Alternative m => [m a] -> m a
orr = foldr (<|>) empty

-- Generic Element wrapper (single child widget)
el_ :: HTMLNodeName [A.Attribute] -> [A.Attribute] -> Widget HTML a -> Widget HTML a
el_ e attrs = wrapView (e attrs)

-- Generic Element wrapper
el :: HTMLNodeName [A.Attribute] -> [A.Attribute] -> [Widget HTML a] -> Widget HTML a
el e attrs = wrapView (e attrs) . orr

-- The transformer version of el_
elT_ :: (MonadTransMap t) => HTMLNodeName [A.Attribute] -> [A.Attribute] -> t (Widget HTML) a -> t (Widget HTML) a
elT_ e attrs = liftMap (wrapView (e attrs))

-- The transformer version of el
elT :: (Alternative (t (Widget HTML)), MonadTransMap t) => HTMLNodeName [A.Attribute] -> [A.Attribute] -> [t (Widget HTML) a] -> t (Widget HTML) a
elT e attrs = liftMap (wrapView (e attrs)) . orr

-- Package a widget inside a div
wrapDiv :: A.Attributes attrs => attrs -> Widget HTML a -> Widget HTML a
wrapDiv attrs = wrapView (E.div attrs)

-- The transformer version of wrapDiv
wrapDivT :: (MonadTransMap t, A.Attributes attrs) => attrs -> t (Widget HTML) a -> t (Widget HTML) a
wrapDivT attrs = liftMap (wrapDiv attrs)

-- Like wrapDiv but takes a list of widgets to match the usual Elm syntax
elDiv :: A.Attributes attrs => attrs -> [Widget HTML a] -> Widget HTML a
elDiv attrs = wrapDiv attrs . orr

-- The transformer version of elDiv
elDivT :: (MonadTransMap t, Alternative (t (Widget HTML)), A.Attributes attrs) => attrs -> [t (Widget HTML) a] -> t (Widget HTML) a
elDivT attrs = wrapDivT attrs . orr

-- Utility to easily create class attributes
classList :: [(String, Bool)] -> A.Attribute
classList xs = A.class_ $ fromString classes
  where classes = intercalate " " $ flip mapMaybe xs $ \(s,c) -> if c then Just s else Nothing
