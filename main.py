def main():
    book_path: str = "books/frankenstein.txt"
    text = get_book_text(book_path)
    word_count = get_num_words(text)
    print(f"{word_count} words found in the document")


def get_book_text(path: str):
    with open(path) as f:
        return f.read()


def get_num_words(text: str) -> int:
    words = text.split()
    word_count: int = len(words)

    return word_count


main()
